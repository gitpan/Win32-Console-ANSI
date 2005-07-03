#!/usr/bin/perl -w
use strict;
use Win32::Clipboard;
use Win32::Event;
use Win32::Process;
$|++;

# Because Test::Harness redirected STDOUT, we create a new console
# for the tests. We use the clipboard as a shared variable between
# the two processes. This ridiculous IPC method works with all
# Windows platforms :-)

my $clip = Win32::Clipboard();
my $ready = Win32::Event->new(1, 0, 'ReadyToReadClipboad');
my $send  = Win32::Event->new(1, 0, 'MessageAvailable');

my $ProcessObj;
Win32::Process::Create($ProcessObj,
                       "$^X",
                       "perl -I$INC[0] -I$INC[1] t\\07_Compatibility2.pl",
                       0,
                       NORMAL_PRIORITY_CLASS | CREATE_NEW_CONSOLE,
                       ".") or die $^E;

my $Response;
while(1) {
  $ready->set();
  $send->wait();
  $Response = $clip->GetText();
  last if $Response eq "_OVER";
  print $Response;
  $send->reset();  
}
  
__END__
