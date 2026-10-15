# Test stub: enough of PVE::Cluster to syntax-check offline.
package PVE::Cluster;
use strict;
use warnings;
use Exporter qw(import);
our @EXPORT_OK = qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
sub cfs_register_file {}
sub cfs_read_file { return { ids => {}, order => {} }; }
sub cfs_lock_file { my (undef, undef, $code) = @_; $code->(); }
sub cfs_write_file {}
1;
