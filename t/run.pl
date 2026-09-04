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

print "\n$ok ok, $nok fehlgeschlagen\n";
exit($nok ? 1 : 0);
