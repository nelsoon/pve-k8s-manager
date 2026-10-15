# Test stub: enough of PVE::SectionConfig to syntax-check offline.
package PVE::SectionConfig;
use strict;
use warnings;
sub import {}
sub parse_config { return { ids => {}, order => {} }; }
sub write_config { return ''; }
sub register {}
sub init {}
1;
