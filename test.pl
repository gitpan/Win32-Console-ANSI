#!/usr/bin/perl -w
use strict;

# Tests for Win32::ANSIConsole
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

#########################
use Win32::Console;
use Win32::Console::ANSI;

my $Out = new Win32::Console (STD_OUTPUT_HANDLE) or die $^E;

my $save = 0;
my $s = '';

# test 01 - load
print "Module loaded Ok\n";
$s .= "test01...........Ok\n" unless $save;

# test 02 - Cursor Position
print "\e[2J";
print "\e[6;23H";
my ($x, $y) = $Out->Cursor();
if ($x==22 and $y==5) {
  $s .= "test02...........Ok\n" unless $save;
}
else {
  $s .= "test02.......failed\n" unless $save;
}

# test 03 - Cursor Movement
print "\e[5C\e[6B\e[2D\e[3A";
($x, $y) = $Out->Cursor();
if ($x==25 and $y==8) {
  $s .= "test03...........Ok\n" unless $save;
}
else {
  $s .= "test03.......failed\n" unless $save;
}

# test 04 - Save and Restore Cursor Position
print "\e[s\n\n\n";
print "\e[u";
if ($x==25 and $y==8) {
  $s .= "test04...........Ok\n" unless $save;
}
else {
  $s .= "test04.......failed\n" unless $save;
}

# test 05 - Cursor Movement (continued)
print "\e[5E\e[2F\e[33G";
($x, $y) = $Out->Cursor();
if ($x==32 and $y==11) {
  $s .= "test05...........Ok\n" unless $save;
}
else {
  $s .= "test05.......failed\n" unless $save;
}

# the end

print "\e[2J\n$s";

