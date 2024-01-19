# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# DiffPlugin is Copyright (C) 2016-2024 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::DiffPlugin;

use strict;
use warnings;

use Foswiki::Func ();

our $VERSION = '3.12';
our $RELEASE = '%$RELEASE%';
our $SHORTDESCRIPTION = 'Compare difference between topics and revisions';
our $LICENSECODE = '%$LICENSECODE%';
our $NO_PREFS_IN_TOPIC = 1;
our $core;

sub initPlugin {

  Foswiki::Func::registerTagHandler('DIFF', sub { return getCore()->handleDiffMacro(@_); });
  Foswiki::Func::registerTagHandler('DIFFCONTROL', sub { return getCore()->handleDiffControlMacro(@_); });

  return 1;
}

sub commonTagsHandler {
  if ($Foswiki::cfg{DiffPlugin}{PatchDiffScript}) {
    my $rdiff = Foswiki::Func::getScriptUrlPath("rdiff");
    my $compare = Foswiki::Func::getScriptUrlPath("compare");
    my $diff = Foswiki::Func::getScriptUrlPath("diff");

    $_[0] =~ s/(?:$rdiff|$compare)/$diff/g;
  }
}

sub diff {
  return getCore()->handleDiffScript(@_);
}

sub getCore {
  unless (defined $core) {
    require Foswiki::Plugins::DiffPlugin::Core;
    $core = Foswiki::Plugins::DiffPlugin::Core->new();
  }
  return $core;
}


sub finishPlugin {
  if ($core) {
    $core->finish();
    undef $core;
  }
}

1;
