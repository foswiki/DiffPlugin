# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# DiffPlugin is Copyright (C) 2016-2022 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::DiffPlugin::Core;

use strict;
use warnings;

BEGIN {
  eval "use Algorithm::Diff::XS qw( sdiff )"; ## no critics
  if ($@) {
    eval "use Algorithm::Diff qw( sdiff )";  ## no critics
    die $@ if $@;
  }
}

use Foswiki::Func ();
use Foswiki::UI ();
use Foswiki::Meta ();
use Foswiki::Time ();
use Foswiki::Serialise ();
use Error qw( :try );

use constant TRACE => 0; # toggle me

sub writeDebug {
  return unless TRACE;
  my ($string, $linefeed) = @_;
  $linefeed = 1 unless defined $linefeed;
  #Foswiki::Func::writeDebug("DiffPlugin::Core - $_[0]");
  print STDERR "DiffPlugin::Core - $_[0]".($linefeed?"\n":"");
}

sub new {
  my $class = shift;

  my $this = bless({
    @_
  }, $class);

  return $this;
}

sub finish {
  my $this = shift;

  undef $this->{_opts};
}

sub addAssets {
  my $this = shift;

  return if $this->{_doneAssets};
  $this->{_doneAssets} = 1;

  Foswiki::Func::addToZone('head', 'DIFFPLUGIN', '<link rel="stylesheet" type="text/css" href="%PUBURLPATH%/System/DiffPlugin/diff.css" media="all" />');
  Foswiki::Func::addToZone('script', 'DIFFPLUGIN', '<script src="%PUBURLPATH%/System/DiffPlugin/diff.js" media="all" ></script>', 'JQUERYPLUGIN::FOSWIKI');
}

sub handleDiffScript {
  my $this = shift;
  my $session = shift;

  my $web = $session->{webName};
  my $topic = $session->{topicName};

  Foswiki::UI::checkWebExists($session, $web, 'diff');
  Foswiki::UI::checkTopicExists($session, $web, $topic, 'diff');

  my $meta = Foswiki::Meta->new($session, $web, $topic);
  my $tmpl = Foswiki::Func::readTemplate("diffview");
  $tmpl = $meta->expandMacros($tmpl);
  $tmpl = $meta->renderTML($tmpl);
  $session->writeCompletePage($tmpl);

  my $rev1 = '';
  my $rev2 = '';
  if ($this->{_opts}) {
    $rev1 = $this->{_opts}{oldRev};
    $rev2 = $this->{_opts}{newRev};
  }

  $session->logEvent('diff', $web . '.' . $topic, "$rev1 $rev2" );

  return;
}

sub _getOpts {
  my ($this, $session, $params, $topic, $web) = @_;

  my %opts = (); 
  my $context = Foswiki::Func::getContext();

  $opts{newWeb} = $web;
  $opts{newTopic} = $params->{_DEFAULT} || $params->{newtopic} || $topic;
  ($opts{newWeb}, $opts{newTopic}) = Foswiki::Func::normalizeWebTopicName($opts{newWeb}, $opts{newTopic});

  return _inlineError("ERROR: topic not found - <nop>$opts{newWeb}.$opts{newTopic}") unless Foswiki::Func::topicExists($opts{newWeb}, $opts{newTopic});
  unless (_hasDiffAccess($opts{newWeb}, $opts{newTopic})) {
    if ($context->{diff}) {
      throw Foswiki::AccessControlException("authenticated", $session->{user}, $opts{newWeb}, $opts{newTopic}, "access denied");
    } else {
      return _inlineError("ERROR: access denied");
    }
  }

  $opts{oldWeb} = $opts{newWeb};
  $opts{oldTopic} = $params->{oldtopic} || $opts{newTopic};
  ($opts{oldWeb}, $opts{oldTopic}) = Foswiki::Func::normalizeWebTopicName($opts{oldWeb}, $opts{oldTopic});

  my $isSameTopic = ($opts{oldWeb} eq $opts{newWeb} && $opts{oldTopic} eq $opts{newTopic})?1:0;

  return _inlineError("ERROR: topic not found - <nop>$opts{oldWeb}.$opts{oldTopic}") unless Foswiki::Func::topicExists($opts{oldWeb}, $opts{oldTopic});
  unless (_hasDiffAccess($opts{oldWeb}, $opts{oldTopic})) {
    if ($context->{diff}) {
      throw Foswiki::AccessControlException("authenticated", $session->{user}, $opts{oldWeb}, $opts{oldTopic}, "access denied");
    } else {
      return _inlineError("ERROR: access denied");
    }
  }

  (undef, undef, $opts{maxNewRev}) = Foswiki::Func::getRevisionInfo($opts{newWeb}, $opts{newTopic});

  if ($isSameTopic) {
    $opts{maxOldRev} = $opts{maxNewRev};
  } else {
    (undef, undef, $opts{maxOldRev}) = Foswiki::Func::getRevisionInfo($opts{oldWeb}, $opts{oldTopic});
  }

  $opts{exclude} = $params->{exclude} // '';
  $opts{newRev} = $params->{rev} || $params->{newrev} || $opts{maxNewRev};
  $opts{newRev} =~ s/[^\d]//g;
  $opts{newRev} = 1 if !$opts{newRev} || $opts{newRev} <= 0;
  $opts{newRev} = $opts{maxNewRev} if $opts{newRev} > $opts{maxNewRev};

  $opts{offset} = $params->{offset} || 1;
  $opts{oldRev} = $params->{oldrev} // '';
  $opts{oldRev} =~ s/[^\d]//g;
  $opts{oldRev} = $opts{newRev} - $opts{offset} if $opts{oldRev} eq '';
  $opts{oldRev} = 1 if $opts{oldRev} <= 0;
  $opts{oldRev} = $opts{maxOldRev} if $opts{oldRev} > $opts{maxOldRev};

  if ($opts{oldRev} > $opts{newRev}) {
    my $tmp = $opts{oldRev};
    $opts{oldRev} = $opts{newRev};
    $opts{newRev} = $tmp;
  }

  $opts{offset} = ($opts{newRev} - $opts{oldRev} < $opts{offset}) ? $opts{offset} : $opts{newRev} - $opts{oldRev};    # finally calculate the real value

  $opts{prevRev} = $opts{newRev} - 1;
  $opts{prevRev} = 1 if $opts{prevRev} < 1;

  $opts{nextRev} = $opts{newRev} + $opts{offset};
  $opts{nextRev} = $opts{maxNewRev} if $opts{nextRev} > $opts{maxNewRev};


  ($opts{newDate}, $opts{newAuthor}, $opts{newTestRev}) = Foswiki::Func::getRevisionInfo($opts{newWeb}, $opts{newTopic}, $opts{newRev});
  ($opts{oldDate}, $opts{oldAuthor}, $opts{oldTestRev}) = Foswiki::Func::getRevisionInfo($opts{oldWeb}, $opts{oldTopic}, $opts{oldRev});

  if ($context->{diff}) {
    $this->{_opts} = \%opts;
  }

  return \%opts;
}

sub _expandVars {
  my ($this, $format, $opts) = @_;

  my $dateTimeFormat = $Foswiki::cfg{DateManipPlugin}{DefaultDateTimeFormat} || $Foswiki::cfg{DefaultDateFormat};

  $format =~ s/\$oldrev/$opts->{oldRev}/g;
  $format =~ s/\$maxoldrev/$opts->{maxOldRev}/g;
  $format =~ s/\$oldweb/$opts->{oldWeb}/g;
  $format =~ s/\$oldtopic/$opts->{oldTopic}/g;
  $format =~ s/\$oldauthor/$opts->{oldAuthor}/g;
  $format =~ s/\$olddate/Foswiki::Time::formatTime($opts->{oldDate}, $dateTimeFormat)/ge;

  $format =~ s/\$newrev/$opts->{newRev}/g;
  $format =~ s/\$maxnewrev/$opts->{maxOldRev}/g;
  $format =~ s/\$newweb/$opts->{newWeb}/g;
  $format =~ s/\$newtopic/$opts->{newTopic}/g;
  $format =~ s/\$newauthor/$opts->{newAuthor}/g;
  $format =~ s/\$newdate/Foswiki::Time::formatTime($opts->{newDate}, $dateTimeFormat)/ge;

  $format =~ s/\$rev/$opts->{newRev}/g;
  $format =~ s/\$maxrev/$opts->{maxNewRev}/g;
  $format =~ s/\$prevrev/$opts->{prevRev}/g;
  $format =~ s/\$nextrev/$opts->{nextRev}/g;
  $format =~ s/\$offset/$opts->{offset}/g;
  $format =~ s/\$exclude/$opts->{exclude}/g;

  return $format;
}


sub handleDiffControlMacro {
  my ($this, $session, $params, $topic, $web) = @_;

  writeDebug("called DIFFCONTROL()");
  my $opts = $this->_getOpts($session, $params, $topic, $web);

  my $template = $params->{template} // "diff::control";
  my $format = $params->{format} // Foswiki::Func::expandTemplate($template);
  my $result = $this->_expandVars($format, $opts);

  return Foswiki::Func::decodeFormatTokens($result);
}

sub handleDiffMacro {
  my ($this, $session, $params, $topic, $web) = @_;

  writeDebug("called DIFF()");
  my $opts = $this->_getOpts($session, $params, $topic, $web);

  $this->addAssets;
  Foswiki::Func::loadTemplate("diff") 
    unless Foswiki::Func::expandTemplate("diff"); # prevent loading it twice

  # SMELL: deep error in store
  #die ("asked for old rev=$opts->{oldRev} but got $oldTestRev") unless $opts->{oldRev} eq $oldTestRev;
  #die ("asked for new rev=$opts->{newRev} but got $newTestRev") unless $opts->{newRev} eq $newTestRev;

  writeDebug("newWeb=$opts->{newWeb}, oldTopic=$opts->{newTopic}, newRev=$opts->{newRev}");
  writeDebug("oldWeb=$opts->{oldWeb}, oldTopic=$opts->{oldTopic}, oldRev=$opts->{oldRev}");

  # nothing to diff
  return "" if $opts->{oldRev} <= 0 || $opts->{newRev} <= 0 || $opts->{oldRev} == $opts->{newRev};

  my ($oldMeta, $oldText) = Foswiki::Func::readTopic($opts->{oldWeb}, $opts->{oldTopic}, $opts->{oldRev});
  my ($newMeta, $newText) = Foswiki::Func::readTopic($opts->{newWeb}, $opts->{newTopic}, $opts->{newRev});

  $params->{beforetext} //= Foswiki::Func::expandTemplate("diff::beforetext");
  $params->{header} //= Foswiki::Func::expandTemplate("diff::header");
  $params->{footer} //= Foswiki::Func::expandTemplate("diff::footer");
  $params->{format} //= Foswiki::Func::expandTemplate("diff::format");
  $params->{meta_format} //= Foswiki::Func::expandTemplate("diff::meta_format");
  $params->{no_differences} //= Foswiki::Func::expandTemplate("diff::no_differences");
  $params->{separator} //= Foswiki::Func::expandTemplate("diff::separator");
  $params->{aftertext} //= Foswiki::Func::expandTemplate("diff::aftertext");
  $params->{context} //= 2;
  $params->{context} =~ s/[^\d]//g;

  my $result = '';

  $result .= _diffText($oldText, $newText, $params);
  $result .= _diffMeta($oldMeta, $newMeta, $params);

  $result = $params->{no_differences} unless $result;
  $result = $params->{beforetext} . $result . $params->{aftertext};

  $result = $this->_expandVars($result, $opts);

  return Foswiki::Func::decodeFormatTokens($result);
}

sub _diffMultiLine {
  my ($oldText, $newText, $context) = @_;

  $context ||= 2;

  my @result = ();

  my @seq1 = split /\r?\n/, $oldText;
  my @seq2 = split /\r?\n/, $newText;

  my @diffs = sdiff(\@seq1, \@seq2);

  my @contextBefore = ();
  my @contextAfter = ();

  my $state = 0;
  my $index = 0;
  foreach my $line (@diffs) {
    my $old = '';
    my $new = '';
    my $action = '';
    $index++;
    if ($line->[0] eq 'c') {
      $action = 'changed';
      ($old, $new) = _diffLine($line->[1], $line->[2]);
    } elsif ($line->[0] eq '-') {
      $action = 'removed';
      $old = _formatDiff([['-', $line->[1]]]);

    } elsif ($line->[0] eq '+') {
      $action = 'append';
      $new = _formatDiff([['+', $line->[2]]]);

    } else {
      $action = 'unchanged';
      $old = _formatDiff([['u', $line->[1]]]);
      $new = _formatDiff([['u', $line->[2]]]);
    }

    my $record = {
      action => $action,
      old => $old,
      new => $new,
      index => $index,
    };

    writeDebug("state=$state, ", 0);
    if ($context < 0) {
      push @result, $record;
    } else {
      if ($action eq 'unchanged') {
        if ($state == 0) {
          writeDebug("$index: unchanged line added to before");
          push @contextBefore, $record;
          shift @contextBefore if scalar(@contextBefore) > $context;
        } elsif ($state == 1) {
          if (scalar(@contextAfter) < $context) {
            writeDebug("$index: unchanged line added to after");
            push @contextAfter, $record;
          } else {
            writeDebug("$index: adding after to result, adding line to before");
            push @result, $_ foreach @contextAfter;
            push @contextBefore, $record;
            @contextAfter = ();
            $state = 0;
          }
        }
      } else {
        if (@contextAfter) {
          writeDebug("$index: adding after to result and adding line to result");
          push @result, $_ foreach @contextAfter;
          @contextAfter = ();
        }
        if (@contextBefore) {
          writeDebug("$index: adding before to result and adding line to result");
          push @result, $_ foreach @contextBefore;
          @contextBefore = ();
        } else {
          writeDebug("$index: adding line to result");
        }
        push @result, $record;
        $state = 1;
      }
    }
  }

  return @result;
}

sub _diffText {
  my ($oldText, $newText, $params) = @_;

  my @result = ();

  my @diffs = _diffMultiLine($oldText, $newText, $params->{context});

  foreach my $record (@diffs) {
    my $line = $params->{format};

    my $old = $record->{old};
    my $new = $record->{new};

    next if $old eq "" && $new eq "";

    $old = '&nbsp;' unless $old ne "";
    $new = '&nbsp;' unless $new ne "";

    $line =~ s/\$action/$record->{action}/g;
    $line =~ s/\$index/$record->{index}/g;
    $line =~ s/\$old/$old/g;
    $line =~ s/\$new/$new/g;

    push @result, $line;
  }

  my $result = "";
  if (@result) {
    $result = $params->{header} . join($params->{separator}, @result) . $params->{footer} if @result;
    $params->{title} //= '%MAKETEXT{"Text"}%';
    $result =~ s/\$title/$params->{title}/g;
    $result =~ s/\$type/TEXT/g;
  }

  return $result;
}

sub _diffMeta {
  my ($oldMeta, $newMeta, $params) = @_;

  my $result = '';

  # parent
  unless ($params->{exclude} && $params->{exclude} =~ /\bparent\b/) {
    $params->{title} = '%MAKETEXT{"Parent topic"}%';
    $result .= _diffText($oldMeta->getParent(), $newMeta->getParent(), $params);
  }

  # form name
  unless ($params->{exclude} && $params->{exclude} =~ /\bform\b/) {
    $params->{title} = '%MAKETEXT{"Form Name"}%';
    $result .= _diffText($oldMeta->getFormName(), $newMeta->getFormName(), $params);
  }

  # form
  unless ($params->{exclude} && $params->{exclude} =~ /\bfields\b/) {
    $params->{title} = '%MAKETEXT{"Form"}%';
    $result .= _diffType($oldMeta, $newMeta, "FIELD", sub {
      my $field = shift;
      return $field->{value};
    }, $params);
  }

  # attachments
  unless ($params->{exclude} && $params->{exclude} =~ /\battachments\b/) {
    $params->{title} = '%MAKETEXT{"Attachments"}%';
    $result .= _diffType($oldMeta, $newMeta, "FILEATTACHMENT", undef, $params);
  }

  # preferences
  unless ($params->{exclude} && $params->{exclude} =~ /\bpreferences\b/) {
    $params->{title} = '%MAKETEXT{"Preferences"}%';
    $result .= _diffType($oldMeta, $newMeta, "PREFERENCE", undef, $params);
  }

  # generic meta data
  my %metaTypes = ();
  $metaTypes{$_} = 1 for grep {!/^_|TOPICINFO|TOPICPARENT|FORM|FIELD|FILEATTACHMENT|PREFERENCE/} keys %$oldMeta;
  $metaTypes{$_} = 1 for grep {!/^_|TOPICINFO|TOPICPARENT|FORM|FIELD|FILEATTACHMENT|PREFERENCE/} keys %$newMeta;
  foreach my $type (sort keys %metaTypes) {
    unless ($params->{exclude} && $params->{exclude} =~ /\b$type\b/i) {
      $params->{title} = '%MAKETEXT{"'.ucfirst(lc($type)).'"}%';
      $result .= _diffType($oldMeta, $newMeta, $type, undef, $params);
    }
  }

  return $result;
}

sub _diffType {
  my ($oldMeta, $newMeta, $type, $getValue, $params) = @_;

  unless ($getValue) {
    $getValue = sub {
      my $field = shift;
      return join("\n", map {$_.": ".($_ eq 'date'?Foswiki::Time::formatTime($field->{$_}):$field->{$_})} grep {!/^(?:attachment|version|name|path)$/} sort keys %$field);
    }
  }

  my @result = ();

  my $state = 0;
  my $index = 0;

  my %fieldNames = ();
  $fieldNames{$_->{name}||''} = 1  for $oldMeta->find($type);
  $fieldNames{$_->{name}||''} = 1  for $newMeta->find($type);

  foreach my $fieldName (sort keys %fieldNames) {
  
    my $old = '';
    my $new = '';
    my $action = '';

    $index++;
    my $oldField = $oldMeta->get($type, $fieldName eq ''? undef: $fieldName);
    my $newField = $newMeta->get($type, $fieldName eq ''? undef: $fieldName);

    if ($oldField) {
      my $oldVal = &$getValue($oldField);
      if ($newField) {
        # unchanged
        my $newVal = &$getValue($newField);

        # clean up a bit
        $oldVal =~ s/\r//g;
        $newVal =~ s/\r//g;
        next if $oldVal eq $newVal;

        # diff values
        $action = 'changed';

        if ($oldVal =~ /\n/ || $newVal =~ /\n/) {
          my @records = _diffMultiLine($oldVal, $newVal, $params->{context});
          foreach my $record (@records) {
            $old .= "\n" . $record->{old};
            $new .= "\n" .$record->{new};
          }
        } else {
          ($old, $new) = _diffLine($oldVal, $newVal);
        }

        next if $old eq $new;

      } else {
        $action = 'removed';
        $old = _formatDiff([['-', $oldVal]]);
      }
    } elsif ($newField) {
      my $newVal = &$getValue($newField);
      $action = 'append';
      $new = _formatDiff([['+', $newVal]]);
    } else {
      # never reach
      next;
    }

    next if $old eq "" && $new eq "";

    $old = '&nbsp;' unless $old ne "";
    $new = '&nbsp;' unless $new ne "";

    my $line = $params->{meta_format};

    $line =~ s/\$action/$action/g;
    $line =~ s/\$old/$old/g;
    $line =~ s/\$new/$new/g;
    $line =~ s/\$index/$index/g;
    $line =~ s/\$name/$fieldName/g;

    push @result, $line;
  }

  my $result = "";
  if (@result) {
    $result = $params->{header} . join($params->{separator}, @result) . $params->{footer} if @result;
    $result =~ s/\$title/$params->{title}||''/ge;
    $result =~ s/\$type/$type/g;
  }

  return $result;
}

sub _formatDiff {
  my ($diff, $sep) = @_;

  $sep = "\n" unless defined $sep;

  return "" unless $diff;

  my $result = "";

  foreach my $line (@$diff) {
    my $part = ref($line->[1])?join($sep, $line->[1]):$line->[1];
    my $before = "";
    my $after = "";
    if ($part =~ /^(\s*)(.*?)(\s*)$/) { # strip off leading and trailing white spaces
      $before = $1 // '';
      $part = $2 // '';
      $after = $3 // '';
    }
    $part =~ s/</&lt;/g;
    $part =~ s/>/&gt;/g;
    $part =~ s/%/%<nop>/g;
    $part =~ s/\$(perce?nt|dollar)/\$<nop>$1/g;
    my $elem;
    if ($line->[0] eq '-') {
      $elem = 'del';
    } elsif ($line->[0] eq '+') {
      $elem = 'ins';
    }
    $result .= $before . (($elem && $part ne '')?"<$elem>$part</$elem>":$part) . $after;
  }

  return $result;
}

sub _diffLine {
  my ($old, $new, $split) = @_;

  $old //= "";
  $new //= "";
  $split ||= '';

  my @seq1 = map {_entityEncode($_)} split /$split/, $old;
  my @seq2 = map {_entityEncode($_)} split /$split/, $new;
  my @diffs = sdiff(\@seq1, \@seq2);

  our @oldDiff = ();
  our @newDiff = ();
  our $prevLine = ['', '', ''];

  sub _distribute { ## no critics
    return unless $prevLine->[0];
    if ($prevLine->[0] eq 'c') {
      # change
      push @oldDiff, ['-', $prevLine->[1]];
      push @newDiff, ['+', $prevLine->[2]];
    } elsif ($prevLine->[0] eq '-') {
      # remove
      push @oldDiff, ['-', $prevLine->[1]];
    } elsif ($prevLine->[0] eq '+') {
      # append
      push @newDiff, ['+', $prevLine->[2]];
    } else {
      # unchage
      push @oldDiff, ['u', $prevLine->[1]];
      push @newDiff, ['u', $prevLine->[2]];
    }
  }

  foreach my $line (@diffs) {
    if ($prevLine->[0] eq $line->[0]) {
      $prevLine->[1] .= $line->[1] // '';
      $prevLine->[2] .= $line->[2] // '';
      next;
    }
    _distribute;
    $prevLine = $line;
  }
  _distribute;


  return (_formatDiff(\@oldDiff, ""), _formatDiff(\@newDiff, ""));
}

sub _entityEncode {
  my $text = shift;

  $text =~ s/([[\x01-\x09\x0b\x0c\x0e-\x1f"%&\$'*<=>@\]_\|])/'&#'.ord($1).';'/ge;
  return $text;
}

sub _hasDiffAccess {
  my ($web, $topic, $meta) = @_;

  my $context = Foswiki::Func::getContext();

  return 1 if $context->{isadmin};

  my $wikiName = Foswiki::Func::getWikiName();

  ($meta) = Foswiki::Func::readTopic($web, $topic) unless $meta;

  # check view
  return 0 unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, $topic, $web, $meta);

  # check raw
  if (defined $Foswiki::cfg{FeatureAccess}{AllowRaw} && $Foswiki::cfg{FeatureAccess}{AllowRaw} ne 'all') {

    if ($Foswiki::cfg{FeatureAccess}{AllowRaw} eq 'authenticated') {
      # authenticated
      return 0 unless $context->{"authenticated"};
    } else {
      # acl
      return 0
        unless Foswiki::Func::checkAccessPermission("CHANGE", $wikiName, undef, $topic, $web, $meta)
        || Foswiki::Func::checkAccessPermission("RAW", $wikiName, undef, $topic, $web, $meta);
    }
  }

  # check history
  if (defined $Foswiki::cfg{FeatureAccess}{AllowHistory} && $Foswiki::cfg{FeatureAccess}{AllowHistory} ne 'all') {

    if ($Foswiki::cfg{FeatureAccess}{AllowHistory} eq 'authenticated') {
      # authenticated
      return 0 unless $context->{"authenticated"};
    } else {
      # acl
      return Foswiki::Func::checkAccessPermission("HISTORY", $wikiName, undef, $topic, $web, $meta);
    }
  }

  return 1;
}

sub _inlineError {
  return '<div class="foswikiAlert">'.$_[0].'</div>';
}


1;
