#!/usr/bin/perl
# Szenario-Tests fuer die Aktivitaets-Readings (last_mowing, idle_hours,
# idle_alert, work_state_since) - ohne FHEM, ohne Python, mit virtueller Uhr.
#
#   perl t/run.pl
#
# Der Fall, um den es geht: der Maeher bleibt nach Regen in "pausiert" stehen
# und tut tagelang nichts - Akku 100 %, kein Fehler. Vorher hat darauf nichts
# hingewiesen. Die Tests stellen genau diesen Ablauf nach.
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;

package main;
use FhemStub;   # use, nicht require: die use-vars-Deklarationen muessen VOR dem Kompilieren dieser Datei gelten


# Modul laden (Initialize wird nicht gebraucht, nur die Subs).
my $modul = "$FindBin::Bin/../FHEM/98_Mammotion.pm";
{
    local $SIG{__WARN__} = sub { };
    do $modul or die "Modul laedt nicht: " . ($@ || $!);
}

my ($ok, $nok) = (0, 0);
sub is {
    my ($got, $exp, $was) = @_;
    $got = defined($got) ? $got : "(undef)";
    if ($got eq $exp) { $ok++; print "ok   $was\n"; }
    else { $nok++; print "FAIL $was\n     erwartet: $exp\n     bekommen: $got\n"; }
}
sub like {
    my ($got, $re, $was) = @_;
    $got = defined($got) ? $got : "(undef)";
    if ($got =~ $re) { $ok++; print "ok   $was\n"; }
    else { $nok++; print "FAIL $was\n     erwartet: /$re/\n     bekommen: $got\n"; }
}

my $name = "Yuka";
sub neu {
    %defs = ($name => { NAME => $name, TYPE => "Mammotion", READINGS => {} });
    %attr = ($name => {});
}
# Ein Status-Poll: work_state-Code wie vom Helper (13 maeht, 19 pausiert, 11 bereit)
sub poll {
    my ($code, $bat) = @_;
    Mammotion_ProcessStatus($defs{$name},
        { work_state => $code, battery => $bat // 100, charge_state => 1 }, FmtDateTime($NOW));
}
sub rd { return ReadingsVal($name, $_[0], "(fehlt)"); }
sub std { $NOW += $_[0] * 3600; }

# ---------------------------------------------------------------------------
print "# 1. Erster Poll ohne Vorgeschichte: Zeit zaehlt ab jetzt, kein Hinweis\n";
neu(); $NOW = 1_756_800_000;
poll(11);
is(rd("work_state"),        "bereit",          "work_state uebersetzt");
is(rd("last_mowing"),       FmtDateTime($NOW), "last_mowing wird beim ersten Poll gesetzt (Startpunkt)");
is(rd("idle_hours"),        "0.0",             "idle_hours startet bei 0");
is(rd("idle_alert"),        "",                "kein Hinweis am Anfang");
is(rd("work_state_since"),  FmtDateTime($NOW), "work_state_since beim ersten Poll gesetzt");

print "# 2. Maehen setzt last_mowing, work_state_since nur bei Wechsel\n";
std(2); poll(13, 80);
my $t_maeht = FmtDateTime($NOW);
is(rd("last_mowing"),      $t_maeht, "last_mowing = jetzt, waehrend gemaeht wird");
is(rd("work_state_since"), $t_maeht, "Zustandswechsel bereit->maeht stempelt work_state_since");
std(0.5); poll(13, 70);
is(rd("last_mowing"),      FmtDateTime($NOW), "last_mowing laeuft mit, solange gemaeht wird");
is(rd("work_state_since"), $t_maeht,          "gleicher Zustand: work_state_since bleibt stehen");
is(rd("idle_hours"),       "0.0",             "beim Maehen keine Leerlaufzeit");
my $letztes_maehen = FmtDateTime($NOW);

print "# 3. Regen: pausiert, und dann passiert drei Tage nichts\n";
std(0.5); poll(19, 75);
my $t_pause = FmtDateTime($NOW);
is(rd("work_state"),       "pausiert", "pausiert erkannt");
is(rd("work_state_since"), $t_pause,   "Beginn der Pause gestempelt");
is(rd("last_mowing"),      $letztes_maehen, "last_mowing bleibt beim letzten Maehen stehen");
is(rd("idle_alert"),       "",         "nach 30 min noch kein Hinweis");
std(20); poll(19);
is(rd("idle_hours"), "20.5", "idle_hours zaehlt seit dem letzten Maehen (20,5 h)");
is(rd("idle_alert"), "",     "unter 48 h kein Hinweis");
std(27.5); poll(19);   # jetzt 48 h
is(rd("idle_hours"), "48.0", "genau 48 h");
like(rd("idle_alert"), qr/^seit 2 Tagen nicht gem.{1,2}ht \(pausiert\)$/, "Hinweis bei 48 h: '2 Tagen', mit Zustand");
std(24); poll(19);
like(rd("idle_alert"), qr/^seit 3 Tagen nicht gem.{1,2}ht \(pausiert\)$/, "nach 72 h: '3 Tagen'");
is(rd("work_state_since"), $t_pause, "work_state_since unveraendert - seit Beginn der Pause");
is(rd("battery"), "100", "Akku voll, kein Fehler - genau der stille Fall");

print "# 4. Er maeht wieder: Hinweis weg, Uhr auf null\n";
std(1); poll(13, 90);
is(rd("idle_alert"), "",   "Hinweis verschwindet beim Maehen");
is(rd("idle_hours"), "0.0", "idle_hours zurueck auf 0");
is(rd("last_mowing"), FmtDateTime($NOW), "last_mowing frisch");

print "# 5. Schwelle per Attribut: 24 h, und 0 schaltet ab\n";
neu(); $NOW = 1_756_800_000;
$attr{$name}{idleAlertHours} = 24;
poll(13); std(1); poll(19); std(23.5); poll(19);
like(rd("idle_alert"), qr/^seit 25 Std\. nicht gem.{1,2}ht/, "idleAlertHours 24 greift (24,5 h -> 25 Std.)");
$attr{$name}{idleAlertHours} = 0;
poll(19);
is(rd("idle_alert"), "", "idleAlertHours 0 = aus");
is(rd("idle_hours"), "24.5", "idle_hours wird trotzdem weiter gefuehrt");

print "# 6. Manuelles Maehen (20) zaehlt auch als Maehen\n";
neu(); $NOW = 1_756_800_000;
poll(19); std(60); poll(20);
is(rd("idle_alert"), "", "manuelles_m\xc3\xa4hen loescht den Hinweis");
is(rd("last_mowing"), FmtDateTime($NOW), "und setzt last_mowing");

print "# 7. Neustart: last_mowing aus dem Statefile bleibt der Bezug\n";
neu(); $NOW = 1_756_800_000;
$defs{$name}{READINGS}{last_mowing} = { VAL => FmtDateTime($NOW - 5 * 86400), TIME => "x" };
poll(19);
like(rd("idle_alert"), qr/^seit 5 Tagen/, "gespeichertes last_mowing wird uebernommen, nicht ueberschrieben");

print "# 8. Dauer-Format\n";
is(Mammotion_Dauer(35 * 60),    "35 min",  "Minuten");
is(Mammotion_Dauer(7 * 3600),   "7 Std.",  "Stunden");
is(Mammotion_Dauer(47 * 3600),  "47 Std.", "bis 48 h Stunden");
is(Mammotion_Dauer(3 * 86400),  "3 Tagen", "ab 48 h Tage");

print "# 9. Leerer Cloud-Datensatz (Akku 0 + nicht aktiv) ueberschreibt den Akku nicht\n";
neu(); $NOW = 1_756_800_000;
poll(13, 92);
is(rd("battery"), "92", "gueltiger Akkustand");
std(0.2); poll(0, 0);
is(rd("battery"), "92", "battery 0 bei work_state 0 wird verworfen");
std(0.2); poll(13, 84);
is(rd("battery"), "84", "naechster gueltiger Wert wird uebernommen");
Mammotion_ProcessStatus($defs{$name}, { work_state => 13, charge_state => 0 }, FmtDateTime($NOW));
is(rd("battery"), "84", "fehlendes battery behaelt den letzten Wert");
poll(13, 0);
is(rd("battery"), "0", "0 % beim Maehen (gueltiger Zustand) wird uebernommen");
neu(); poll(0, 0);
is(rd("battery"), "0", "ohne Vorwert wird 0 gesetzt (wie bisher)");

print "# 10. Helper meldet no_report: nichts wird ueberschrieben\n";
neu(); $NOW = 1_756_800_000;
poll(13, 80);
Mammotion_ProcessStatus($defs{$name}, { no_report => 1, waited => 15 }, FmtDateTime($NOW));
is(rd("battery"), "80", "Akku bleibt");
is(rd("work_state"), "maeht", "work_state bleibt");
is(rd("last_error"), "", "kein Fehler gesetzt");

print "# 11. Zusatzfelder (pymammotion 0.10.x)\n";
neu(); $NOW = 1_756_800_000;
Mammotion_ProcessStatus($defs{$name}, { work_state => 11, battery => 63, charge_state => 2,
    last_status => 13, self_check_status => 20, mow_percent => 47, error_codes => [],
    session => { interrupted => 1, interrupt_type => 7, end => 1_756_799_000, progress => 47 } },
    FmtDateTime($NOW));
is(rd("last_work_state"), "maeht", "last_status als Klartext");
is(rd("block_reason"), "Regen", "self_check 20 -> Regen");
is(rd("mow_percent"), "47", "Fortschritt");
is(rd("error_codes"), "", "keine Fehler");
is(rd("last_interrupt"), "schlechte Positionierung (7)", "Abbruchgrund");
is(rd("last_session_end"), FmtDateTime(1_756_799_000), "Auftragsende");
Mammotion_ProcessStatus($defs{$name}, { work_state => 11, battery => 63, charge_state => 2,
    self_check_status => 99, error_codes => [1234], error_text => "Testfehler", error_time => 1_756_799_500,
    session => { interrupted => 0, end => 1_756_799_000_000 } }, FmtDateTime($NOW));
is(rd("block_reason"), "Code 99", "unbekannter Code roh");
is(rd("error_codes"), "1234", "Fehlercode");
is(rd("error_text"), "Testfehler", "Fehlertext");
is(rd("last_interrupt"), "schlechte Positionierung (7)", "gleiches Auftragsende (ms) aendert nichts");
Mammotion_ProcessStatus($defs{$name}, { work_state => 11, battery => 63, charge_state => 2,
    self_check_status => 0 }, FmtDateTime($NOW));
is(rd("block_reason"), "", "0 = keine Sperre");
is(rd("error_codes"), "1234", "ohne error_codes im Datensatz bleibt der alte Wert");

print "# 12. pause_alert: pausiert draussen\n";
neu(); $NOW = 1_756_800_000;
Mammotion_ProcessStatus($defs{$name}, { work_state => 13, battery => 90, charge_state => 0 }, FmtDateTime($NOW));
std(0.05); Mammotion_ProcessStatus($defs{$name}, { work_state => 19, battery => 88, charge_state => 0 }, FmtDateTime($NOW));
is(rd("pause_alert"), "", "gerade erst pausiert: kein Hinweis");
std(0.5); Mammotion_ProcessStatus($defs{$name}, { work_state => 19, battery => 87, charge_state => 0 }, FmtDateTime($NOW));
like(rd("pause_alert"), qr/^steht seit 30 min pausiert drau.{1,2}en \(Akku 87 %\)$/, "nach 30 min Hinweis");
Mammotion_ProcessStatus($defs{$name}, { work_state => 19, battery => 87, charge_state => 1 }, FmtDateTime($NOW));
is(rd("pause_alert"), "", "pausiert aber laedt (Station): kein Hinweis");
Mammotion_ProcessStatus($defs{$name}, { work_state => 19, battery => 87, charge_state => 0 }, FmtDateTime($NOW));
$attr{$name}{pauseAlertMinutes} = 0;
Mammotion_ProcessStatus($defs{$name}, { work_state => 19, battery => 87, charge_state => 0 }, FmtDateTime($NOW));
is(rd("pause_alert"), "", "pauseAlertMinutes 0 = aus");
$attr{$name}{pauseAlertMinutes} = 15;
Mammotion_ProcessStatus($defs{$name}, { work_state => 11, battery => 87, charge_state => 0 }, FmtDateTime($NOW));
is(rd("pause_alert"), "", "anderer Zustand loescht den Hinweis");

print "\n$ok ok, $nok fehlgeschlagen\n";
exit($nok ? 1 : 0);
