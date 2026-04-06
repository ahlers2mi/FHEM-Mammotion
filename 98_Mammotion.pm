##############################################################################
# 98_Mammotion.pm
#
# FHEM-Modul fuer Mammotion Rasenmaeher (Luba, Yuka etc.)
# Kommuniziert via pymammotion Python-Bibliothek mit der Mammotion Cloud.
#
# Definition:
#   define <name> Mammotion <account> <password> [<device_name>]
#
# Beispiel:
#   define Yuka Mammotion 62525974 MeinPasswort Yuka-ABC123
#
##############################################################################

package main;

use strict;
use warnings;
use JSON;
use POSIX qw(strftime);
use IPC::Open3;
use Symbol 'gensym';

my $moduleName   = "Mammotion";
my $helperScript = "/opt/fhem/FHEM/mammotion_helper.py";
my $pythonBin    = "/usr/bin/python3.13";
my $MODULE_VERSION = "1.3.0";

my %sets = (
    "update"       => "noArg",
    "start"        => "noArg",
    "stop"         => "noArg",
    "pause"        => "noArg",
    "resume"       => "noArg",
    "return_home"  => "noArg",
    "leave_dock"   => "noArg",
    "along_border" => "noArg",
    "start_zone"   => "textField",
    "start_task"   => "textField",
    "selectDevice" => "textField",
);

my %gets = (
    "devices" => "noArg",
    "zones"   => "noArg",
    "tasks"   => "noArg",
    "status"  => "noArg",
);

sub Mammotion_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}    = "Mammotion_Define";
    $hash->{UndefFn}  = "Mammotion_Undef";
    $hash->{SetFn}    = "Mammotion_Set";
    $hash->{GetFn}    = "Mammotion_Get";
    $hash->{AttrFn}   = "Mammotion_Attr";
    $hash->{AttrList} = "interval:60,120,300,600 "
                      . "python_bin "
                      . "helper_script "
                      . $readingFnAttributes;
    $hash->{MODULE_VERSION} = $MODULE_VERSION;

    foreach my $d (keys %defs) {
        if (defined($defs{$d}{TYPE}) && $defs{$d}{TYPE} eq "Mammotion") {
            $defs{$d}{RUNNING} = 0;
            Log3($d, 3, "[$d] RUNNING-Flag beim Modulload zurueckgesetzt.");
        }
    }

    Log3(undef, 3, "[$moduleName] Modul geladen.");
}

sub Mammotion_Define {
    my ($hash, $def) = @_;
    my @args = split("[ \t][ \t]*", $def);

    if (@args < 4) {
        return "Verwendung: define <name> Mammotion <account> <password> [<device_name>]";
    }

    my $name       = $args[0];
    my $account    = $args[2];
    my $password   = $args[3];
    my $deviceName = $args[4] // "";

    $hash->{NAME}        = $name;
    $hash->{ACCOUNT}     = $account;
    $hash->{PASSWORD}    = $password;
    $hash->{DEVICE_NAME} = $deviceName;
    $hash->{IOT_ID}      = "";
    $hash->{STATE}       = "initialized";
    $hash->{MODULE_VERSION} = $MODULE_VERSION;
    $hash->{INTERVAL}    = AttrVal($name, "interval", 300);
    $hash->{RUNNING}     = 0;

    Log3($name, 3, "[$name] Mammotion definiert. Account: $account, Geraet: $deviceName");

    InternalTimer(gettimeofday() + 30, "Mammotion_UpdateTimer", $hash, 0);
    readingsSingleUpdate($hash, "state", "initialized", 1);

    return undef;
}

sub Mammotion_Undef {
    my ($hash, $arg) = @_;
    RemoveInternalTimer($hash);
    BlockingKill($hash->{helper}) if (defined($hash->{helper}));
    $hash->{RUNNING} = 0;
    return undef;
}

sub Mammotion_BuildSetList {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my %dynamic_sets = %sets;

    # Zones as dropdown for start_zone
    my $zones_json = ReadingsVal($name, "zones_json", "");
    if ($zones_json) {
        my $zones;
        eval { $zones = decode_json($zones_json) };
        if ($zones && @$zones) {
            my $zone_options = join(",", map { my $n = $_->{name}; $n =~ s/[ ,]/_/g; $n } @$zones);
            $dynamic_sets{"start_zone"} = $zone_options if $zone_options;
        }
    }

    # Tasks as dropdown for start_task
    my $tasks_json = ReadingsVal($name, "tasks_json", "");
    if ($tasks_json) {
        my $tasks;
        eval { $tasks = decode_json($tasks_json) };
        if ($tasks && @$tasks) {
            my $task_options = join(",", map { my $n = $_->{name}; $n =~ s/[ ,]/_/g; $n } @$tasks);
            $dynamic_sets{"start_task"} = $task_options if $task_options;
        }
    }

    return join(" ", map {
        $dynamic_sets{$_} eq "noArg" ? $_ : "$_:$dynamic_sets{$_}"
    } sort keys %dynamic_sets);
}

sub Mammotion_Set {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd eq "?") {
        return "Unknown argument $cmd, choose one of " . Mammotion_BuildSetList($hash);
    }

    if (!exists($sets{$cmd})) {
        return "Unknown argument $cmd, choose one of " . Mammotion_BuildSetList($hash);
    }

    if ($cmd eq "update") {
        Log3($name, 4, "[$name] Manuelles Update angefordert.");
        Mammotion_FetchDevices($hash);
        return undef;
    }

    if ($cmd eq "selectDevice") {
        if (!@args) {
            return "Bitte Geraetename angeben: set $name selectDevice <device_name>";
        }
        my $selectedDevice = join(" ", @args);
        $hash->{DEVICE_NAME} = $selectedDevice;
        $hash->{IOT_ID}      = "";
        Log3($name, 3, "[$name] Geraet gewaehlt: $selectedDevice");
        readingsSingleUpdate($hash, "selected_device", $selectedDevice, 1);
        Mammotion_FetchDevices($hash);
        return undef;
    }

    my $deviceName = $hash->{DEVICE_NAME};
    my $iotId      = $hash->{IOT_ID};
    if (!$iotId) {
        $iotId = ReadingsVal($name, "iot_id", "");
    }

    if (!$deviceName || !$iotId) {
        return "Kein Geraet oder IoT-ID. Bitte erst: set $name update";
    }

    if ($cmd eq "start_zone") {
        if (!@args) {
            my $zones_json = ReadingsVal($name, "zones_json", "");
            if ($zones_json) {
                my $zones;
                eval { $zones = decode_json($zones_json) };
                if ($zones && @$zones) {
                    return "Bitte Zone-Hash oder Name angeben: set $name start_zone <hash_oder_name>\nVerfuegbare Zonen: " .
                           join(", ", map { "$_->{name} (Hash: $_->{hash})" } @$zones);
                }
            }
            return "Bitte Zone-Hash oder Name angeben: set $name start_zone <hash_oder_name>. Erst 'get $name zones' ausfuehren.";
        }
        my $zone_input = join(" ", @args);
        my $zone_hash  = $zone_input;

        # If not a pure integer: try to resolve by name
        if ($zone_input !~ /^\d+$/) {
            my $zones_json = ReadingsVal($name, "zones_json", "");
            if ($zones_json) {
                my $zones;
                eval { $zones = decode_json($zones_json) };
                if ($zones && @$zones) {
                    my ($found) = grep { lc($_->{name}) eq lc($zone_input) } @$zones;
                    if ($found) {
                        $zone_hash = $found->{hash};
                    } else {
                        my $available = join(", ", map { "$_->{name} (Hash: $_->{hash})" } @$zones);
                        return "Zone '$zone_input' nicht gefunden. Verfuegbare Zonen: $available";
                    }
                }
            }
        }

        Log3($name, 3, "[$name] Starte Zone: $zone_hash (Eingabe: $zone_input)");
        Mammotion_SendCommand($hash, "start_zone", $deviceName, $iotId, $zone_hash);
        return undef;
    }

    if ($cmd eq "start_task") {
        if (!@args) {
            my $tasks_json = ReadingsVal($name, "tasks_json", "");
            if ($tasks_json) {
                my $tasks;
                eval { $tasks = decode_json($tasks_json) };
                if ($tasks && @$tasks) {
                    return "Bitte Task-Name angeben: set $name start_task <name>\nVerfuegbare Aufgaben: " .
                           join(", ", map { "$_->{name}" } @$tasks);
                }
            }
            return "Bitte Task-Name angeben: set $name start_task <name>. Erst 'get $name tasks' ausfuehren.";
        }
        my $task_input = join(" ", @args);

        # Look up plan_id from tasks_json (dropdown sends underscores instead of spaces)
        my $plan_id_to_use;
        my $tasks_json = ReadingsVal($name, "tasks_json", "");
        if ($tasks_json) {
            my $tasks;
            eval { $tasks = decode_json($tasks_json) };
            if ($tasks && @$tasks) {
                for my $t (@$tasks) {
                    my $tname = $t->{name} // "";
                    (my $tname_norm = $tname) =~ s/[ ,]/_/g;
                    if (   lc($tname_norm) eq lc($task_input)
                        || lc($tname)      eq lc($task_input)
                        || ($t->{id} // "") eq $task_input)
                    {
                        $plan_id_to_use = $t->{plan_id};
                        last;
                    }
                }
                if (!$plan_id_to_use) {
                    my $available = join(", ", map { $_->{name} } @$tasks);
                    return "Aufgabe '$task_input' nicht gefunden. Verfuegbare Aufgaben: $available";
                }
            }
        }
        if (!$plan_id_to_use) {
            return "Task '$task_input' nicht gefunden. Bitte erst 'get $name tasks' ausfuehren.";
        }

        Log3($name, 3, "[$name] Starte Aufgabe: $task_input (plan_id: $plan_id_to_use)");
        Mammotion_SendCommand($hash, "start_task", $deviceName, $iotId, $plan_id_to_use);
        return undef;
    }

    my %cmd_map = (
        "start"        => "start_mowing",
        "stop"         => "stop_mowing",
        "pause"        => "pause_mowing",
        "resume"       => "resume_mowing",
        "return_home"  => "return_home",
        "leave_dock"   => "leave_dock",
        "along_border" => "along_border",
    );

    if (exists($cmd_map{$cmd})) {
        my $action = $cmd_map{$cmd};
        Log3($name, 3, "[$name] Befehl: $cmd -> $action");
        Mammotion_SendCommand($hash, $action, $deviceName, $iotId);
        return undef;
    }

    return undef;
}

sub Mammotion_Get {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd eq "?") {
        my $list = join(" ", map { "$_: $gets{$_}" } sort keys %gets);
        return "Unknown argument $cmd, choose one of $list";
    }

    if (!exists($gets{$cmd})) {
        my $list = join(" ", map { "$_: $gets{$_}" } sort keys %gets);
        return "Unknown argument $cmd, choose one of $list";
    }

    if ($cmd eq "devices") {
        my $json = ReadingsVal($name, "device_list_json", undef);
        if (!$json) {
            return "Keine Geraete. Bitte erst: set $name update";
        }
        my $devices;
        eval { $devices = decode_json($json) };
        if ($@ || !$devices) {
            return "Fehler beim Lesen der Geraete.";
        }
        my $out = "Gefundene Geraete (" . scalar(@$devices) . "):\n";
        $out .= "-" x 60 . "\n";
        my $i = 1;
        for my $d (@$devices) {
            my $st = ($d->{status} == 1) ? "online" : "offline";
            $out .= sprintf("%d. %-25s  Typ: %-15s  Status: %s\n",
                $i++,
                $d->{device_name} // "unbekannt",
                $d->{device_type} // "unbekannt",
                $st
            );
            $out .= sprintf("   IoT-ID:  %s\n", $d->{iot_id}      // "");
            $out .= sprintf("   Serie:   %s\n", $d->{series}      // "");
            $out .= sprintf("   Aktiv:   %s\n", $d->{active_time} // "");
            $out .= "\n";
        }
        return $out;
    }

    if ($cmd eq "zones") {
        my $deviceName = $hash->{DEVICE_NAME};
        my $iotId      = $hash->{IOT_ID} // ReadingsVal($name, "iot_id", "");
        if (!$deviceName || !$iotId) {
            return "Kein Geraet. Bitte erst: set $name update";
        }
        Log3($name, 3, "[$name] Zonen-Abfrage gestartet...");
        Mammotion_SendCommand($hash, "get_zones", $deviceName, $iotId);
        return "Zonen werden abgefragt, bitte kurz warten...";
    }

    if ($cmd eq "tasks") {
        my $deviceName = $hash->{DEVICE_NAME};
        my $iotId      = $hash->{IOT_ID} // ReadingsVal($name, "iot_id", "");
        if (!$deviceName || !$iotId) {
            return "Kein Geraet. Bitte erst: set $name update";
        }
        Log3($name, 3, "[$name] Aufgaben-Abfrage gestartet...");
        Mammotion_SendCommand($hash, "get_tasks", $deviceName, $iotId);
        return "Aufgaben werden abgefragt, bitte kurz warten...";
    }

    if ($cmd eq "status") {
        my $state    = ReadingsVal($name, "state",        "unbekannt");
        my $devname  = ReadingsVal($name, "device_name",  "unbekannt");
        my $devtype  = ReadingsVal($name, "device_type",  "unbekannt");
        my $iot_id   = ReadingsVal($name, "iot_id",       "unbekannt");
        my $battery  = ReadingsVal($name, "battery",      "?");
        my $work     = ReadingsVal($name, "work_state",   "?");
        my $charge   = ReadingsVal($name, "charge_state", "?");
        my $last_upd = ReadingsVal($name, "last_update",  "nie");
        my $last_err = ReadingsVal($name, "last_error",   "");
        my $last_cmd = ReadingsVal($name, "last_command", "");

        my $out = "Status von $name:\n";
        $out .= "-" x 40 . "\n";
        $out .= "  Geraet:         $devname\n";
        $out .= "  Typ:            $devtype\n";
        $out .= "  IoT-ID:         $iot_id\n";
        $out .= "  Cloud-Status:   $state\n";
        $out .= "  Arbeitsstatus:  $work\n";
        $out .= "  Ladestatus:     $charge\n";
        $out .= "  Akku:           $battery%\n";
        $out .= "  Letzter Befehl: $last_cmd\n" if $last_cmd;
        $out .= "  Letztes Update: $last_upd\n";
        $out .= "  Letzter Fehler: $last_err\n" if $last_err;

        my $zones_json = ReadingsVal($name, "zones_json", "");
        if ($zones_json) {
            my $zones;
            eval { $zones = decode_json($zones_json) };
            if ($zones && @$zones) {
                $out .= "\n  Verfuegbare Zonen (" . scalar(@$zones) . "):\n";
                for my $z (@$zones) {
                    $out .= sprintf("    Hash: %-12s  Name: %s\n",
                        $z->{hash} // "?",
                        $z->{name} // "unbekannt"
                    );
                }
            }
        }

        my $tasks_json = ReadingsVal($name, "tasks_json", "");
        if ($tasks_json) {
            my $tasks;
            eval { $tasks = decode_json($tasks_json) };
            if ($tasks && @$tasks) {
                $out .= "\n  Verfuegbare Aufgaben (" . scalar(@$tasks) . "):\n";
                for my $t (@$tasks) {
                    $out .= sprintf("    ID: %-6s  Name: %s\n",
                        $t->{id}   // "?",
                        $t->{name} // "unbekannt"
                    );
                }
            }
        }
        return $out;
    }

    return undef;
}

sub Mammotion_Attr {
    my ($cmd, $name, $attr, $val) = @_;
    my $hash = $defs{$name};

    if ($attr eq "interval") {
        RemoveInternalTimer($hash);
        $hash->{INTERVAL} = $val;
        InternalTimer(gettimeofday() + $val, "Mammotion_UpdateTimer", $hash, 0);
        Log3($name, 3, "[$name] Polling-Intervall geaendert: $val Sekunden");
    }

    return undef;
}

sub Mammotion_UpdateTimer {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    Mammotion_FetchDevices($hash);

    my $interval = AttrVal($name, "interval", $hash->{INTERVAL} // 300);
    InternalTimer(gettimeofday() + $interval, "Mammotion_UpdateTimer", $hash, 0);
}

sub Mammotion_FetchDevices {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    if ($hash->{RUNNING}) {
        Log3($name, 3, "[$name] Aufruf laeuft bereits, ueberspringe.");
        return;
    }

    my $py     = AttrVal($name, "python_bin",    $pythonBin);
    my $script = AttrVal($name, "helper_script", $helperScript);

    if (!-f $script) {
        Log3($name, 1, "[$name] FEHLER: Helper nicht gefunden: $script");
        readingsSingleUpdate($hash, "last_error", "Helper nicht gefunden", 1);
        readingsSingleUpdate($hash, "state", "error", 1);
        return;
    }

    Log3($name, 4, "[$name] Starte Python-Aufruf (get_devices)...");
    $hash->{RUNNING} = 1;
    readingsSingleUpdate($hash, "state", "updating", 1);

    my $arg = join("\x1F", $name, $hash->{ACCOUNT}, $hash->{PASSWORD},
                   $py, $script, "get_devices");

    $hash->{helper} = BlockingCall(
        "Mammotion_PythonCall",
        $arg,
        "Mammotion_PythonDone",
        60,
        "Mammotion_PythonTimeout",
        $hash
    );

    if (!defined($hash->{helper})) {
        Log3($name, 2, "[$name] BlockingCall fehlgeschlagen!");
        $hash->{RUNNING} = 0;
        readingsSingleUpdate($hash, "state", "error", 1);
    }
}

sub Mammotion_SendCommand {
    my ($hash, $action, $deviceName, $iotId, @extra) = @_;
    my $name = $hash->{NAME};

    if ($hash->{RUNNING}) {
        Log3($name, 3, "[$name] Aufruf laeuft bereits, ueberspringe: $action");
        return;
    }

    my $py     = AttrVal($name, "python_bin",    $pythonBin);
    my $script = AttrVal($name, "helper_script", $helperScript);

    Log3($name, 3, "[$name] Sende Befehl: $action an $deviceName");
    $hash->{RUNNING} = 1;
    readingsSingleUpdate($hash, "state", "sending", 1);

    my $arg = join("\x1F", $name, $hash->{ACCOUNT}, $hash->{PASSWORD},
                   $py, $script, $action, $deviceName, $iotId, @extra);

    my $timeout = ($action =~ /^(get_zones|start_zone|get_tasks|start_task)$/) ? 180 :
                  ($action eq "get_status") ? 60 : 90;

    $hash->{helper} = BlockingCall(
        "Mammotion_PythonCall",
        $arg,
        "Mammotion_PythonDone",
        $timeout,
        "Mammotion_PythonTimeout",
        $hash
    );

    if (!defined($hash->{helper})) {
        Log3($name, 2, "[$name] BlockingCall fuer $action fehlgeschlagen!");
        $hash->{RUNNING} = 0;
        readingsSingleUpdate($hash, "state", "error", 1);
    }
}

sub Mammotion_PythonCall {
    my ($arg) = @_;

    my ($name, $account, $password, $py, $script, $action, @params) = split(/\x1F/, $arg);

    Log3($name, 5, "[$name] Fuehre aus: $py $script <account> <password> $action @params");

    my $stderr_fh = gensym;
    my ($stdout_content, $stderr_content) = ("", "");

    eval {
        my @cmd = ($py, $script, $account, $password, $action, @params);
        my $fhem_verbose = AttrVal($name, "verbose", 3);
        push @cmd, "-v" if $fhem_verbose >= 5;
        my $pid = open3(my $stdin, my $stdout, $stderr_fh, @cmd);
        close($stdin);

        while (my $line = <$stdout>) {
            $stdout_content .= $line;
        }
        while (my $line = <$stderr_fh>) {
            $stderr_content .= $line;
        }
        waitpid($pid, 0);
    };

    my $exit_code = $? >> 8;

    if ($@) {
        return "$name|ERROR|open3-Fehler";
    }

    if ($stderr_content) {
        Log3($name, 4, "[$name] Python stderr: $stderr_content");
    }

    if ($exit_code != 0) {
        $stdout_content =~ s/'//g;
        $stdout_content =~ s/"//g;
        $stderr_content =~ s/'//g;
        $stderr_content =~ s/"//g;
        return "$name|ERROR|Exit-Code $exit_code: $stdout_content";
    }

    my $json_line = "";
    for my $line (reverse split(/\n/, $stdout_content)) {
        $line =~ s/^\s+|\s+$//g;
        if ($line =~ /^\{/) {
            $json_line = $line;
            last;
        }
    }

    if (!$json_line) {
        return "$name|ERROR|Keine JSON-Ausgabe";
    }

    return "$name|OK|$json_line";
}

sub Mammotion_PythonDone {
    my ($result) = @_;

    my ($name, $status, $data) = split(/\|/, $result, 3);
    my $hash = $defs{$name};

    if (!$hash) {
        Log3($name, 1, "[$name] PythonDone: Hash nicht gefunden!");
        return;
    }

    delete $hash->{helper};
    $hash->{RUNNING} = 0;

    my $timestamp = strftime("%Y-%m-%d %H:%M:%S", localtime());

    if ($status eq "ERROR") {
        Log3($name, 2, "[$name] Fehler: $data");
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "last_error",  $data);
        readingsBulkUpdate($hash, "state",       "error");
        readingsBulkUpdate($hash, "last_update", $timestamp);
        readingsEndUpdate($hash, 1);
        return;
    }

    my $json_data;
    eval { $json_data = decode_json($data) };
    if ($@) {
        Log3($name, 2, "[$name] JSON-Parse-Fehler");
        readingsSingleUpdate($hash, "last_error", "JSON-Parse-Fehler", 1);
        readingsSingleUpdate($hash, "state", "error", 1);
        return;
    }

    if (!$json_data->{ok}) {
        my $err = $json_data->{error} // "unbekannt";
        Log3($name, 2, "[$name] API-Fehler: $err");
        readingsSingleUpdate($hash, "last_error", $err, 1);
        readingsSingleUpdate($hash, "state", "error", 1);
        return;
    }

    my $action = $json_data->{action} // "";

    if ($action eq "" || $action eq "get_devices") {
        Mammotion_ProcessDevices($hash, $json_data, $timestamp);
        return;
    }

    if ($action eq "get_zones") {
        my @zones = @{$json_data->{zones} // []};
        Log3($name, 3, "[$name] " . scalar(@zones) . " Zonen gefunden.");

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "zones_json",  encode_json(\@zones));
        readingsBulkUpdate($hash, "zones_count", scalar @zones);
        readingsBulkUpdate($hash, "last_update", $timestamp);
        readingsBulkUpdate($hash, "last_error",  "");

        my $i = 0;
        for my $z (@zones) {
            readingsBulkUpdate($hash, "zone_${i}_hash", $z->{hash} // "");
            readingsBulkUpdate($hash, "zone_${i}_name", $z->{name} // "");
            $i++;
        }
        readingsBulkUpdate($hash, "state", "online");
        readingsEndUpdate($hash, 1);

        for my $z (@zones) {
            Log3($name, 3, "[$name] Zone: $z->{name} (Hash: $z->{hash})");
        }
        return;
    }

    if ($action eq "get_tasks") {
        my @tasks = @{$json_data->{tasks} // []};
        Log3($name, 3, "[$name] " . scalar(@tasks) . " Aufgaben gefunden.");

        # Debug-Info loggen wenn vorhanden
        if (defined $json_data->{debug} && ref($json_data->{debug}) eq 'HASH') {
            my $debug = $json_data->{debug};
            Log3($name, 3, "[$name] DEBUG mower-Attribute: " . join(", ", keys %$debug));
            for my $k (sort keys %$debug) {
                Log3($name, 4, "[$name] DEBUG $k = $debug->{$k}");
            }
        }

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "tasks_json",  encode_json(\@tasks));
        readingsBulkUpdate($hash, "tasks_count", scalar @tasks);
        readingsBulkUpdate($hash, "last_update", $timestamp);
        readingsBulkUpdate($hash, "last_error",  "");

        my $i = 0;
        for my $t (@tasks) {
            readingsBulkUpdate($hash, "task_${i}_id",   $t->{id}   // "");
            readingsBulkUpdate($hash, "task_${i}_name",  $t->{name} // "");
            $i++;
        }
        readingsBulkUpdate($hash, "state", "online");
        readingsEndUpdate($hash, 1);

        for my $t (@tasks) {
            Log3($name, 3, "[$name] Aufgabe: $t->{name} (ID: $t->{id})");
        }
        return;
    }

    if ($action =~ /^(start_mowing|stop_mowing|pause_mowing|resume_mowing|return_home|leave_dock|along_border|start_zone|start_task)$/) {
        Log3($name, 3, "[$name] Befehl erfolgreich: $action");
        my %state_map = (
            "start_mowing"  => "mowing",
            "stop_mowing"   => "idle",
            "pause_mowing"  => "paused",
            "resume_mowing" => "mowing",
            "return_home"   => "returning",
            "leave_dock"    => "online",
            "along_border"  => "border_mode",
            "start_zone"    => "mowing",
            "start_task"    => "mowing",
        );
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash, "last_command", $action);
        readingsBulkUpdate($hash, "last_update",  $timestamp);
        readingsBulkUpdate($hash, "last_error",   "");
        readingsBulkUpdate($hash, "state",        $state_map{$action} // "online");
        readingsEndUpdate($hash, 1);
        return;
    }

    if ($action eq "get_status") {
        Mammotion_ProcessStatus($hash, $json_data, $timestamp);
        return;
    }
}

sub Mammotion_ProcessStatus {
    my ($hash, $data, $timestamp) = @_;
    my $name = $hash->{NAME};

    my $charge_state = $data->{charge_state} // 0;
    my $battery      = $data->{battery}      // 0;
    my $work_state   = $data->{work_state}   // 0;

    my %charge_texts = (0 => "nicht laden", 1 => "laden", 2 => "voll");
    my $charge_text  = $charge_texts{$charge_state} // "unbekannt ($charge_state)";

    my %work_texts = (
        0 => "idle", 1 => "mowing", 2 => "going_home",
        3 => "charging", 4 => "emergency_stop", 5 => "paused",
        6 => "park", 7 => "border"
    );
    my $work_text = $work_texts{$work_state} // "unbekannt ($work_state)";

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "battery",      $battery);
    readingsBulkUpdate($hash, "charge_state", $charge_text);
    readingsBulkUpdate($hash, "work_state",   $work_text);
    readingsBulkUpdate($hash, "last_update",  $timestamp);
    readingsBulkUpdate($hash, "last_error",   "");
    readingsBulkUpdate($hash, "state",        "online");
    readingsEndUpdate($hash, 1);

    Log3($name, 4, "[$name] Status: Akku=$battery%, Arbeit=$work_text, Laden=$charge_text");
}

sub Mammotion_ProcessDevices {
    my ($hash, $json_data, $timestamp) = @_;
    my $name = $hash->{NAME};

    my @devices = @{$json_data->{devices} // []};

    if (!@devices) {
        Log3($name, 3, "[$name] Keine Geraete gefunden.");
        readingsSingleUpdate($hash, "state", "no_devices", 1);
        return;
    }

    my $targetName = $hash->{DEVICE_NAME} // "";
    my $device;

    if ($targetName) {
        ($device) = grep {
            lc($_->{device_name}) eq lc($targetName) ||
            lc($_->{iot_id})      eq lc($targetName)
        } @devices;
        if (!$device) {
            Log3($name, 3, "[$name] Geraet '$targetName' nicht gefunden, nehme erstes.");
        }
    }
    $device //= $devices[0];

    $hash->{IOT_ID} = $device->{iot_id} // "";

    readingsBeginUpdate($hash);

    my $i = 0;
    for my $d (@devices) {
        my $p = "device_${i}";
        readingsBulkUpdate($hash, "${p}_name",   $d->{device_name} // "");
        readingsBulkUpdate($hash, "${p}_type",   $d->{device_type} // "");
        readingsBulkUpdate($hash, "${p}_iot_id", $d->{iot_id}      // "");
        readingsBulkUpdate($hash, "${p}_status",
            ($d->{status} == 1) ? "online" : "offline");
        $i++;
    }

    readingsBulkUpdate($hash, "device_count",     scalar @devices);
    readingsBulkUpdate($hash, "device_name",      $device->{device_name} // "");
    readingsBulkUpdate($hash, "device_type",      $device->{device_type} // "");
    readingsBulkUpdate($hash, "iot_id",           $device->{iot_id}      // "");
    readingsBulkUpdate($hash, "device_id",        $device->{device_id}   // "");
    readingsBulkUpdate($hash, "series",           $device->{series}      // "");
    readingsBulkUpdate($hash, "generation",       $device->{generation}  // 0);
    readingsBulkUpdate($hash, "active_time",      $device->{active_time} // "");
    readingsBulkUpdate($hash, "device_list_json", encode_json(\@devices));
    readingsBulkUpdate($hash, "last_update",      $timestamp);
    readingsBulkUpdate($hash, "last_error",       "");

    my $status_num = $device->{status} // 0;
    my $state_str  = ($status_num == 1) ? "online" : "offline";
    readingsBulkUpdate($hash, "status", $status_num);
    readingsBulkUpdate($hash, "state",  $state_str);
    readingsEndUpdate($hash, 1);

    Log3($name, 3, "[$name] Update OK. $i Geraet(e). Aktiv: ${\ $device->{device_name}} ($state_str) IoT-ID: ${\ $hash->{IOT_ID}};");

    # Automatically fetch device status shortly after device update
    my $devName = $hash->{DEVICE_NAME} // $device->{device_name};
    my $iotId   = $hash->{IOT_ID};
    InternalTimer(gettimeofday() + 2, sub {
        Mammotion_SendCommand($hash, "get_status", $devName, $iotId);
    }, $hash, 0);
}

sub Mammotion_PythonTimeout {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    delete $hash->{helper};
    $hash->{RUNNING} = 0;
    Log3($name, 2, "[$name] Timeout!");
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "last_error", "Timeout");
    readingsBulkUpdate($hash, "state",      "timeout");
    readingsEndUpdate($hash, 1);
}

1;

=pod
=item device
=item summary Mammotion Rasenmaeher (Luba, Yuka) via Cloud-API
=item summary_DE Mammotion Rasenmaeher (Luba, Yuka) via Cloud-API

=begin html

<a name="Mammotion"></a>
<h3>Mammotion</h3>
<ul>
  Steuert Mammotion Rasenmaeher ueber die Cloud API.
  Benoetigt Python 3.13 mit pymammotion.<br><br>

  <b>Define:</b><br>
  <ul>
    <code>define &lt;name&gt; Mammotion &lt;account&gt; &lt;password&gt; [&lt;device_name&gt;]</code>
  </ul><br>

  <b>Set:</b>
  <ul>
    <li><code>update</code> - Geraete aktualisieren</li>
    <li><code>start</code> - Maehvorgang starten</li>
    <li><code>stop</code> - Stoppen</li>
    <li><code>pause</code> - Pausieren</li>
    <li><code>resume</code> - Weiter nach Pause</li>
    <li><code>return_home</code> - Zur Ladestation</li>
    <li><code>leave_dock</code> - Ladestation verlassen</li>
    <li><code>along_border</code> - Randmodus</li>
    <li><code>start_zone &lt;hash_oder_name&gt;</code> - Bestimmte Zone maehen (Hash oder Name)</li>
    <li><code>start_task &lt;id_oder_name&gt;</code> - Bestimmte Aufgabe starten (ID oder Name)</li>
    <li><code>selectDevice &lt;name&gt;</code> - Geraet waehlen</li>
  </ul><br>

  <b>Get:</b>
  <ul>
    <li><code>devices</code> - Alle Geraete</li>
    <li><code>zones</code> - Verfuegbare Maehzonen abrufen</li>
    <li><code>tasks</code> - Verfuegbare Aufgaben abrufen</li>
    <li><code>status</code> - Status inkl. Zonen und Aufgaben</li>
  </ul><br>

  <b>Workflow Zonen-Maehen:</b><br>
  <ul>
    <li>1. <code>get &lt;name&gt; zones</code> - Zonen laden</li>
    <li>2. <code>set &lt;name&gt; start_zone &lt;hash_oder_name&gt;</code> - Zone starten</li>
  </ul>

  <b>Workflow Aufgaben:</b><br>
  <ul>
    <li>1. <code>get &lt;name&gt; tasks</code> - Aufgaben laden</li>
    <li>2. <code>set &lt;name&gt; start_task &lt;id_oder_name&gt;</code> - Aufgabe starten</li>
  </ul>
</ul>

=end html
=cut