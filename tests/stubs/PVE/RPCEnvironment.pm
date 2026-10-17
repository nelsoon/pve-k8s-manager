# Stub for local `perl -c` only; the real module ships with PVE.
package PVE::RPCEnvironment;

use strict;
use warnings;

sub get { return bless {}, shift }
sub get_user { return 'root@pam' }
sub fork_worker { return 'UPID:stub' }

1;
