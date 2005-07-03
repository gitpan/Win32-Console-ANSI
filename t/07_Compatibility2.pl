#!/usr/bin/perl -w
use strict;
use Win32::Clipboard;
use Win32::Event;
use Win32::Console::ANSI qw( Cls Cursor Title XYMax SetConsoleSize);
use Digest::MD5 qw(md5_hex);
# module Term::ANSIScreen installed ?
my $ANSIScreenOk;
BEGIN {eval "use Term::ANSIScreen qw/:color :cursor :screen /;";
             $ANSIScreenOk = $@ ? 0 : 1;}

close STDOUT;                 # needed for Win9x
open STDOUT, '+> CONOUT$';
binmode STDOUT;
select STDOUT;
$|++;

my $clip  = Win32::Clipboard();
my $ready = Win32::Event->open('ReadyToReadClipboad');
my $send  = Win32::Event->open('MessageAvailable');
my $n;

my $s;
my $dig;
my @dig;
my $save = 0;

if ($save) {
  # open DIG, "> t\\07.data" or die $!;
}
else {
  open DIG, "t\\07.data" or die $!;
  @dig = <DIG>;
  close DIG;
  chomp @dig;
}

sub ok {
  my $t = shift;
  ++$n;
  $ready->wait();
  $clip->Set($t ? "ok $n\n":"not ok $n\n");
  $ready->reset();
  $send->set();
}

sub skipped {
  ++$n;
  $ready->wait();
  $clip->Set("ok $n # skip");
  $ready->reset();
  $send->set();
}

sub comp {            # compare screendump MD5 digests
  my $skip = shift;
  ++$n;
  my $digest = md5_hex(Win32::Console::ANSI::_ScreenDump());
  if ($save) {
    if ( $skip) {
      push @dig, $digest;
      return;
    }    
    if ( <STDIN> eq "\n" ) {
      push @dig, $digest;
    }
    else {
      push @dig, "__ $n";
    }
  }
  else {
    $ready->wait();
    my $dig = shift @dig;
    $clip->Set($digest eq $dig ? "ok $n\n":"not ok $n\n");
    $ready->reset();
    $send->set();  
  }
}

$ready->wait();
if ($ANSIScreenOk) {
  $clip->Set("1..12\n");        # <================= test plan
  $ready->reset();
  $send->set();
  
  # ****************************** BEGIN TESTS
  
  SetConsoleSize(80, 25);
  my ($Xmax, $Ymax) = XYMax();
  
  
  # ======== tests for 
  
  # test 01                   locate
  Cls;
  locate( 5, 7);
  my ($x, $y) = Cursor();
  ok( $x==7 and $y==5 );
  
  # test 02                   up
  up(2);
  ($x, $y) = Cursor();
  ok( $x==7 and $y==3 );
  
  # test 03                   down
  down(3);
  ($x, $y) = Cursor();
  ok( $x==7 and $y==6 );
  
  # test 04                   left
  left(3);
  ($x, $y) = Cursor();
  ok( $x==4 and $y==6 );
  
  # test 05                   right
  right(5);
  ($x, $y) = Cursor();
  ok( $x==9 and $y==6 );
  
  # test 06                   savepos, loadpos
  print savepos(), "1234567890", loadpos();
  ($x, $y) = Cursor();
  ok( $x==9 and $y==6 );
  
  # test 07                   locate
  locate();
  ($x, $y) = Cursor();
  ok( $x==1 and $y==1 ); 
  
  # test 08                   cls
  print"\e[1;31;43maaa\nbbbbbb\n\nxxxxx";
  cls();
  # sleep 5 if $save;
  comp(1);
  
  # test 09                   cls
  print"\e[m";
  cls();
  # sleep 5 if $save;
  comp(1);
  
  # bug in Term::ANSIScreen: clline == \e[K != \e[2K
  # test 10                   clline
  print"\e[m\e[2J";
  print '1234567890'x8 for (0..23);
  print '-'x79;
  locate(5, 25);
  # sleep 5 if $save;
  clline();
  comp(1);
  
  # test 11                   clup
  print"\e[m\e[2J";
  print '1234567890'x8 for (0..23);
  print '-'x79;
  locate(5, 25);
  # sleep 5 if $save;
  clup();
  comp(1);
  
  # test 12                   cldown
  print"\e[m\e[2J";
  print '1234567890'x8 for (0..23);
  print '-'x79;
  locate(5, 25);
  # sleep 5 if $save;
  cldown();
  comp(1);
    
  # ****************************** END TESTS
  
  if ($save) {
    open DIG, "> t\\07.data" or die $!;
    local $, = "\n";
    print DIG @dig;
    close DIG;
  }
}
else {
  $clip->Set("1..0 # Skipped: Term::ANSIScreen not installed\n");
  $ready->reset();
  $send->set();
}
$ready->wait();
$clip->Set("_OVER");
$ready->reset();
$send->set();

__END__
