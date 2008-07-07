#!/usr/bin/perl -w
use strict;
use Win32::Clipboard;
use Win32::Event;
use Win32::Console::ANSI qw( Cursor Title XYMax Cls ScriptCP );

close STDOUT;                 # needed for Win9x
open STDOUT, '+> CONOUT$';
binmode STDOUT;
select STDOUT;
$|++;

my $clip  = Win32::Clipboard();
my $ready = Win32::Event->open('ReadyToReadClipboad');
my $send  = Win32::Event->open('MessageAvailable');
my $n;

sub ok {
  my $t = shift;
  ++$n;
  $ready->wait();
  $clip->Set($t ? "ok $n\n":"not ok $n\n");
  $ready->reset();
  $send->set();
}

$ready->wait();
$clip->Set("1..29\n");        # <== test plan
$ready->reset();
$send->set();

# ====== BEGIN TESTS

my ($Xmax, $Ymax) = XYMax();

# ======== tests Cursor function

# test 01 
Cls();
my ($x, $y) = Cursor();
my ($x1, $y1) = Cursor();
ok( $x==$x1 and $y==$y1 );   


# test 02 
print "\e[2J";             # clear screen
($x, $y) = Cursor();
ok( $x==1 and $y==1 );   # origin

# test 03
print "\n\n123456";
($x, $y) = Cursor();
ok( $x==7 and $y==3 );

# test 04
Cursor(17, 8);
($x, $y) = Cursor();
ok( $x==17 and $y==8 );

# test 05
Cursor($Xmax-1, 8);            # cursor max right
($x, $y) = Cursor();
ok( $x==$Xmax-1 and $y==8 );

# test 06
Cursor($Xmax   , 8);            
($x, $y) = Cursor();
ok( $x==$Xmax and $y==8 );

# test 07
Cursor($Xmax+1, 8);            
($x, $y) = Cursor();
ok( $x==$Xmax and $y==8 );

# test 08
Cursor(1000, 8);            
($x, $y) = Cursor();
ok( $x==$Xmax and $y==8 );

# test 09
($x, $y) = Cursor(0, 0);    # don't move
ok( $x==$Xmax and $y==8 );

# test 10
Cursor(1, 8);            # cursor max left
($x, $y) = Cursor();
ok( $x==1 and $y==8 );

# test 11
Cursor(0, 8);            
($x, $y) = Cursor();
ok( $x==1 and $y==8 );

# test 12
Cursor(-1, 8);            
($x, $y) = Cursor();
ok( $x==1 and $y==8 );

# test 13
Cursor(-1000, 8);            
($x, $y) = Cursor();
ok( $x==1 and $y==8 );

# test 14                # cursor max up
Cursor(17, 5);            
($x, $y) = Cursor();
ok( $x==17 and $y==5 );

# test 15              
Cursor(17, 1);            
($x, $y) = Cursor();
ok( $x==17 and $y==1 );

# test 16      
Cursor(17, 5);        
Cursor(17, 0);            
($x, $y) = Cursor();
ok( $x==17 and $y==5 );

# test 17             
Cursor(17, -1);            
($x, $y) = Cursor();
ok( $x==17 and $y==1 );

# test 18    
Cursor(17, 5);           
Cursor(17, -1000);            
($x, $y) = Cursor();
ok( $x==17 and $y==1 );

# test 19                # cursor max down
Cursor(17, $Ymax-1);            
($x, $y) = Cursor();
ok( $x==17 and $y==$Ymax-1 );

# test 20    
Cursor(17, 5);           
Cursor(17, $Ymax);            
($x, $y) = Cursor();
ok( $x==17 and $y==$Ymax );

# test 21   
Cursor(17, 5);           
Cursor(17, $Ymax+1);            
($x, $y) = Cursor();
ok( $x==17 and $y==$Ymax );

# test 22    
Cursor(17, 5);           
Cursor(17, 1000);            
($x, $y) = Cursor();
ok( $x==17 and $y==$Ymax );

# test 23                # all max
Cursor(17, 5);           
Cursor(1200 , 1000);            
($x, $y) = Cursor();
ok( $x==$Xmax and $y==$Ymax );

# ======== tests Title function

my $new_title1 = 'The console title number 1';
my $new_title2 = 'The console title number 2';

# test 24   
Title($new_title1);
my $title = Title();
ok( $title eq $new_title1 );

# test 25   
$title = Title();
ok( $title eq $new_title1 );

# test 26   
$title = Title($new_title2);
ok( $title eq $new_title1 );

# test 27   
$title = Title();
ok( $title eq $new_title2 );

# ======== tests ScriptCP function

# test 28
my $old_cp = ScriptCP();
my $cp = ScriptCP();
ok( $cp == $old_cp );

# test 29
ScriptCP(1250);
$cp = ScriptCP();
ok( $cp == 1250 );

ScriptCP($old_cp);



# ====== END TESTS

$ready->wait();
$clip->Set("_OVER");
$ready->reset();
$send->set();

__END__
