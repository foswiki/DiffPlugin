# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# DiffPlugin is Copyright (C) 2016-2018 Michael Daum http://michaeldaumconsulting.com
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
  eval "use Algorithm::Diff::XS qw( sdiff );";
  if ($@) {
    eval "use Algorithm::Diff qw( sdiff );"; 
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

sub addAssets {
  my $this = shift;

  return if $this->{_doneAssets};
  $this->{_doneAssets} = 1;

  Foswiki::Func::addToZone('head', 'DIFFPLUGIN', '<link rel="stylesheet" type="text/css" href="%PUBURLPATH%/System/DiffPlugin/diff.css" media="all" />');
}

sub handleDiffScript {
  my $this = shift;
  my $session = shift;

  my $web = $session->{webName};
  my $topic = $session->{topicName};

  Foswiki::UI::checkWebExists($session, $web, 'diff');
  Foswiki::UI::checkTopicExists($session, $web, $topic, 'diff');

  my $meta = Foswiki::Meta->new($session, $web, $topic);
  my $tmpl = Foswiki::Func::readTemplate("diff");
  $tmpl = $meta->expandMacros($tmpl);
  $tmpl = $meta->renderTML($tmpl);
  $session->writeCompletePage($tmpl);

  return;
}

sub handleDiffMacro {
  my ($this, $session, $params, $topic, $web) = @_;

  writeDebug("called DIFF()");
  my $newWeb = $web;
  my $newTopic = $params->{_DEFAULT} || $params->{newtopic} || $topic;
  ($newWeb, $newTopic) = Foswiki::Func::normalizeWebTopicName($newWeb, $newTopic);

  my $context = Foswiki::Func::getContext();

  return _inlineError("ERROR: topic not found - <nop>$newWeb.$newTopic") unless Foswiki::Func::topicExists($newWeb, $newTopic);
  unless (_hasDiffAccess($newWeb, $newTopic)) {
    if ($context->{diff}) {
      throw Foswiki::AccessControlException("authenticated", $session->{user}, $newWeb, $newTopic, "access denied");
    } else {
      return _inlineError("ERROR: access denied");
    }
  }

  my $oldWeb = $newWeb;
  my $oldTopic = $params->{oldtopic} || $newTopic;
  ($oldWeb, $oldTopic) = Foswiki::Func::normalizeWebTopicName($oldWeb, $oldTopic);

  my $isSameTopic = ($oldWeb eq $newWeb && $oldTopic eq $newTopic)?1:0;

  return _inlineError("ERROR: topic not found - <nop>$oldWeb.$oldTopic") unless Foswiki::Func::topicExists($oldWeb, $oldTopic);
  unless (_hasDiffAccess($oldWeb, $oldTopic)) {
    if ($context->{diff}) {
      throw Foswiki::AccessControlException("authenticated", $session->{user}, $oldWeb, $oldTopic, "access denied");
    } else {
      return _inlineError("ERROR: access denied");
    }
  }

  $this->addAssets;
  Foswiki::Func::loadTemplate("diff");

  my $maxNewRev;
  my $maxOldRev;
  (undef, undef, $maxNewRev) = Foswiki::Func::getRevisionInfo($newWeb, $newTopic);

  if ($isSameTopic) {
    $maxOldRev = $maxNewRev;
  } else {
    (undef, undef, $maxOldRev) = Foswiki::Func::getRevisionInfo($oldWeb, $oldTopic);
  }

  my $newRev = $params->{rev} || $params->{newrev} || $maxNewRev;
  $newRev =~ s/[^\d]//g;
  $newRev = 1 if !$newRev || $newRev <= 0;
  $newRev = $maxNewRev if $newRev > $maxNewRev;

  my $offset = $params->{offset} || 1;
  my $oldRev = $params->{oldrev} // '';
  $oldRev =~ s/[^\d]//g;
  $oldRev = $newRev - $offset if $oldRev eq '';
  $oldRev = 1 if $oldRev <= 0;
  $oldRev = $maxOldRev if $oldRev > $maxOldRev;

  if ($oldRev > $newRev) {
    my $tmp = $oldRev;
    $oldRev = $newRev;
    $newRev = $tmp;
  }


  $offset = ($newRev - $oldRev < $offset) ? $offset : $newRev - $oldRev;    # finally calculate the real value

  my ($newDate, $newAuthor, $newTestRev) = Foswiki::Func::getRevisionInfo($newWeb, $newTopic, $newRev);
  my ($oldDate, $oldAuthor, $oldTestRev) = Foswiki::Func::getRevisionInfo($oldWeb, $oldTopic, $oldRev);

  # SMELL: deep error in store
  #die ("asked for old rev=$oldRev but got $oldTestRev") unless $oldRev eq $oldTestRev;
  #die ("asked for new rev=$newRev but got $newTestRev") unless $newRev eq $newTestRev;

  writeDebug("newWeb=$newWeb, oldTopic=$newTopic, newRev=$newRev");
  writeDebug("oldWeb=$oldWeb, oldTopic=$oldTopic, oldRev=$oldRev");

  # nothing to diff
  return "" if $oldRev <= 0 || $newRev <= 0 || $oldRev == $newRev;

  my ($oldMeta, $oldText) = Foswiki::Func::readTopic($oldWeb, $oldTopic, $oldRev);
  my ($newMeta, $newText) = Foswiki::Func::readTopic($newWeb, $newTopic, $newRev);

  $params->{beforetext} //= Foswiki::Func::expandTemplate("diff::beforetext");
  $params->{header} //= Foswiki::Func::expandTemplate("diff::header");
  $params->{footer} //= Foswiki::Func::expandTemplate("diff::footer");
  $params->{format} //= Foswiki::Func::expandTemplate("diff::format");
  $params->{meta_format} //= Foswiki::Func::expandTemplate("diff::meta_format");
  $params->{no_differences} //= Foswiki::Func::expandTemplate("diff::no_differences");
  $params->{separator} //= Foswiki::Func::expandTemplate("diff::separator");
  $params->{aftertext} //= Foswiki::Func::expandTemplate("diff::aftertext");

  $params->{context} //= 2;
  $params->{context} =~ s/[^\d\-]//g;
  $params->{context} //= 2;

  my $result = '';

  $result .= _diffText($oldText, $newText, $params);
  $result .= _diffMeta($oldMeta, $newMeta, $params);

  $result = $params->{no_differences} unless $result;
  $result = $params->{beforetext} . $result . $params->{aftertext};

  $result =~ s/\$oldrev/$oldRev/g;
  $result =~ s/\$maxoldrev/$maxOldRev/g;
  $result =~ s/\$oldweb/$oldWeb/g;
  $result =~ s/\$oldtopic/$oldTopic/g;
  $result =~ s/\$oldauthor/$oldAuthor/g;
  $result =~ s/\$olddate/Foswiki::Time::formatTime($oldDate)/ge;

  $result =~ s/\$newrev/$newRev/g;
  $result =~ s/\$maxnewrev/$maxOldRev/g;
  $result =~ s/\$newweb/$newWeb/g;
  $result =~ s/\$newtopic/$newTopic/g;
  $result =~ s/\$newauthor/$newAuthor/g;
  $result =~ s/\$newdate/Foswiki::Time::formatTime($newDate)/ge;

  my $prevRev = $newRev - 1;
  $prevRev = 1 if $prevRev < 1;

  my $nextRev = $newRev + $offset;
  $nextRev = $maxNewRev if $nextRev > $maxNewRev;

  $result =~ s/\$rev/$newRev/g;
  $result =~ s/\$maxrev/$maxNewRev/g;
  $result =~ s/\$prevrev/$prevRev/g;
  $result =~ s/\$nextrev/$nextRev/g;
  $result =~ s/\$offset/$offset/g;

  return Foswiki::Func::decodeFormatTokens($result);
}

sub _diffText {
  my ($oldText, $newText, $params) = @_;

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

    next if $old eq "" && $new eq "";

    $old = '&nbsp;' unless $old ne "";
    $new = '&nbsp;' unless $new ne "";

    my $line = $params->{format};

    $line =~ s/\$action/$action/g;
    $line =~ s/\$old/$old/g;
    $line =~ s/\$new/$new/g;
    $line =~ s/\$index/$index/g;

    writeDebug("state=$state, ", 0);
    if ($params->{context} < 0) {
      push @result, $line;
    } else {
      if ($action eq 'unchanged') {
        if ($state == 0) {
          writeDebug("$index: unchanged line added to before");
          push @contextBefore, $line;
          shift @contextBefore if scalar(@contextBefore) > $params->{context};
        } elsif ($state == 1) {
          if (scalar(@contextAfter) < $params->{context}) {
            writeDebug("$index: unchanged line added to after");
            push @contextAfter, $line;
          } else {
            writeDebug("$index: adding after to result, adding line to before");
            push @result, @contextAfter if @contextAfter;
            push @contextBefore, $line;
            @contextAfter = ();
            $state = 0;
          }
        }
      } else {
        if (@contextAfter) {
          writeDebug("$index: adding after to result and adding line to result");
          push @result, @contextAfter;
          @contextAfter = ();
        }
        if (@contextBefore) {
          writeDebug("$index: adding before to result and adding line to result");
          push @result, @contextBefore;
          @contextBefore = ();
        } else {
          writeDebug("$index: adding line to result");
        }
        push @result, $line;
        $state = 1;
      }
    }
  }
  push @result, @contextAfter if $state == 1 && @contextAfter;

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
  $params->{title} = '%MAKETEXT{"Parent topic"}%';
  $result .= _diffText($oldMeta->getParent(), $newMeta->getParent(), $params);

  # form name
  $params->{title} = '%MAKETEXT{"Form Name"}%';
  $result .= _diffText($oldMeta->getFormName(), $newMeta->getFormName(), $params);

  # form
  $params->{title} = '%MAKETEXT{"Form"}%';
  $result .= _diffType($oldMeta, $newMeta, "FIELD", sub {
    my $field = shift;
    return $field->{value};
  }, $params);

  # attachments
  $params->{title} = '%MAKETEXT{"Attachments"}%';
  $result .= _diffType($oldMeta, $newMeta, "FILEATTACHMENT", undef, $params);

  # preferences
  $params->{title} = '%MAKETEXT{"Preferences"}%';
  $result .= _diffType($oldMeta, $newMeta, "PREFERENCE", undef, $params);

  # generic meta data
  my %metaTypes = ();
  $metaTypes{$_} = 1 for grep {!/^_|TOPICINFO|TOPICPARENT|FORM|FIELD|FILEATTACHMENT|PREFERENCE/} keys %$oldMeta;
  $metaTypes{$_} = 1 for grep {!/^_|TOPICINFO|TOPICPARENT|FORM|FIELD|FILEATTACHMENT|PREFERENCE/} keys %$newMeta;
  foreach my $type (sort keys %metaTypes) {
    $params->{title} = '%MAKETEXT{"'.ucfirst(lc($type)).'"}%';
    $result .= _diffType($oldMeta, $newMeta, $type, undef, $params);
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
    my $oldField = $oldMeta->get($type, $fieldName);
    my $newField = $newMeta->get($type, $fieldName);

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
        ($old, $new) = _diffLine($oldVal, $newVal);
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

  return ("", "") unless $old && $new;

  $split ||= '';

  my @seq1 = map {_entityEncode($_)} split /$split/, $old;
  my @seq2 = map {_entityEncode($_)} split /$split/, $new;
  my @diffs = sdiff(\@seq1, \@seq2);

  our @oldDiff = ();
  our @newDiff = ();
  our $prevLine = ['', '', ''];

  sub _distribute {
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
