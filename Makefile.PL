use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'Win32::Console::ANSI',
    'VERSION_FROM'	=> 'ANSI.pm', # finds $VERSION
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'ANSI.pm', # retrieve abstract from module
       AUTHOR     => 'J-L. Morel <jl_morel@bribes.org>') : ()),
);
