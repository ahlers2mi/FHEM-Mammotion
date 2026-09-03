# FHEM-Attrappe fuer die Tests unter t/ - genug, damit 98_Mammotion.pm laedt
# und Mammotion_ProcessStatus laeuft, ohne FHEM-Installation und ohne Python.
#
# Die Uhr ist VIRTUELL: time() liefert $main::NOW. Drei Tage "pausiert" sind
# damit ein Aufruf mit $NOW += 3*86400 - genau der Fall, um den es geht.
package main;

use strict;
use warnings;

# use vars statt our: das Modul wird per "do" in eigenem lexikalischem Bereich
# geladen, ein "our" hier wuerde dort unter "use strict" nicht gelten.
# fhem.pl macht es genauso (use vars qw(%defs ...)).
use vars qw(%defs %attr %modules $init_done $readingFnAttributes $NOW @LOG @TIMER @EVENTS);
$init_done = 1;
$readingFnAttributes = "event-on-change-reading";
$NOW = 1_756_800_000;        # 2026-09-02 08:00 UTC, irgendein fester Anker

# @LOG [level, text] · @TIMER [zeit, funktion, arg] · @EVENTS geaenderte Readings

BEGIN { *CORE::GLOBAL::time = sub { return $main::NOW; }; }
sub gettimeofday { return $NOW; }

sub Log3 { my ($n, $l, $t) = @_; push @LOG, [$l, $t]; return undef; }

sub AttrVal {
    my ($d, $a, $def) = @_;
    return (defined($attr{$d}) && defined($attr{$d}{$a})) ? $attr{$d}{$a} : $def;
}
sub ReadingsVal {
    my ($d, $r, $def) = @_;
    return (defined($defs{$d}) && defined($defs{$d}{READINGS}{$r}))
        ? $defs{$d}{READINGS}{$r}{VAL} : $def;
}
sub ReadingsTimestamp {
    my ($d, $r, $def) = @_;
    return (defined($defs{$d}) && defined($defs{$d}{READINGS}{$r}))
        ? $defs{$d}{READINGS}{$r}{TIME} : $def;
}

# Wie fhem.pl: BulkUpdate schreibt sofort (ReadingsVal sieht den neuen Wert),
# das Ereignis kaeme erst bei EndUpdate. Wir merken uns nur, was geaendert wurde.
sub readingsBeginUpdate { my ($h) = @_; $h->{".updateTimestamp"} = FmtDateTime($NOW); return 1; }
sub readingsEndUpdate   { return 1; }
sub readingsBulkUpdate {
    my ($hash, $r, $v) = @_;
    my $alt = $hash->{READINGS}{$r}{VAL};
    push @EVENTS, "$r: $v" if (!defined($alt) || $alt ne $v);
    $hash->{READINGS}{$r} = { VAL => $v, TIME => FmtDateTime($NOW) };
    return 1;
}
sub readingsSingleUpdate {
    my ($hash, $r, $v) = @_;
    return readingsBulkUpdate($hash, $r, $v);
}

# fhem.pl-Originale (Zeitformat "YYYY-MM-DD HH:MM:SS", lokale Zeit)
sub FmtDateTime {
    my ($t) = @_;
    my @l = localtime($t);
    return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
                   $l[5] + 1900, $l[4] + 1, $l[3], $l[2], $l[1], $l[0]);
}
sub time_str2num {
    my ($s) = @_;
    my @a = split(/[\s:-]+/, $s);
    return 0 if (@a < 6);
    require Time::Local;
    return Time::Local::timelocal($a[5], $a[4], $a[3], $a[2], $a[1] - 1, $a[0] - 1900);
}

sub InternalTimer       { my ($t, $fn, $arg) = @_; push @TIMER, [$t, $fn, $arg]; return undef; }
sub RemoveInternalTimer { @TIMER = (); return undef; }
sub BlockingCall        { return { pid => 4711 }; }
sub BlockingKill        { return undef; }

1;
