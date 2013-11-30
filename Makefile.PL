
use strict;
use warnings;



use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "App::Fetchware is Fetchware's API used to make extensions.",
  "AUTHOR" => "David Yingling <deeelwy\@gmail.com>",
  "BUILD_REQUIRES" => {},
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "App-Fetchware",
  "EXE_FILES" => [
    "bin/fetchware"
  ],
  "LICENSE" => "perl",
  "NAME" => "App::Fetchware",
  "PREREQ_PM" => {
    "Archive::Tar" => 0,
    "Archive::Zip" => 0,
    "Digest::MD5" => 0,
    "Digest::SHA" => 0,
    "File::HomeDir" => 0,
    "Getopt::Long" => 0,
    "HTML::TreeBuilder" => 0,
    "HTTP::Tiny" => 0,
    "Path::Class" => 0,
    "Perl::OSType" => 0,
    "Privileges::Drop" => 0,
    "Sub::Mage" => 0,
    "Term::UI" => 0,
    "Test::More" => "0.98",
    "Text::ParseWords" => 0,
    "URI" => 0
  },
  "TEST_REQUIRES" => {
    "Test::Deep" => 0
  },
  "VERSION" => "1.008",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


my %FallbackPrereqs = (
  "Archive::Tar" => 0,
  "Archive::Zip" => 0,
  "Digest::MD5" => 0,
  "Digest::SHA" => 0,
  "File::HomeDir" => 0,
  "Getopt::Long" => 0,
  "HTML::TreeBuilder" => 0,
  "HTTP::Tiny" => 0,
  "Path::Class" => 0,
  "Perl::OSType" => 0,
  "Privileges::Drop" => 0,
  "Sub::Mage" => 0,
  "Term::UI" => 0,
  "Test::Deep" => 0,
  "Test::More" => "0.98",
  "Text::ParseWords" => 0,
  "URI" => 0
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.63_03) } ) {
  delete $WriteMakefileArgs{TEST_REQUIRES};
  delete $WriteMakefileArgs{BUILD_REQUIRES};
  $WriteMakefileArgs{PREREQ_PM} = \%FallbackPrereqs;
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

if ( $^O eq 'MSWin32' ) {
	$WriteMakefileArgs{PREREQ_PM}{'Win32'} = '0';
}

WriteMakefile(%WriteMakefileArgs);



