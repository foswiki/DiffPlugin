# ---+ Extensions
# ---++ DiffPlugin
# This is the configuration used by the <b>DiffPlugin</b>.

# **PERL EXPERT**
# This setting is required to enable executing the xsendfile service from the bin directory
$Foswiki::cfg{SwitchBoard}{diff} = {
  package  => 'Foswiki::Plugins::DiffPlugin',
  function => 'diff',
  context  => { diff => 1 },
};

# **BOOLEAN**
# Replace calls to the <code>rdiff</code> and <code>compare</code> scripts with <code>diff</code> 
$Foswiki::cfg{DiffPlugin}{PatchDiffScript} = 1;

1;
