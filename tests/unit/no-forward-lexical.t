# Static test: no lexical (`my sub`) in Provision.pm may
# be called from above its declaration point. Perl
# resolves the call to the package stash instead, fails at
# runtime with "Undefined subroutine", and any eval around
# it silently degrades (seen live: joined_names always
# fell back to live-VM names because kubectl_on was
# declared 1900 lines below). Run via `make test`.
use strict;
use warnings;
use Test::More;

my $file = 'PVE/K8s/Provision.pm';
open(my $fh, '<', $file) or die "open $file: $!\n";
my @src = <$fh>;
close($fh);

my %decl;
for my $i (0 .. $#src) {
    if ($src[$i] =~ /^(my\s+)?sub\s+(\w+)/) {
        $decl{$2} = { line => $i + 1, lex => defined $1 };
    }
}
my @violations;
for my $name (keys %decl) {
    next if !$decl{$name}{lex};
    my $dl = $decl{$name}{line};
    for my $i (0 .. $dl - 2) {
        my $l = $src[$i];
        next if $l =~ /^\s*(my\s+)?sub\s+/;
        if ($l =~ /(?<![\w:>{$-])\Q$name\E\s*\(/) {
            push @violations, "$name (declared $dl) called at "
                . ($i + 1) . ": $l";
        }
    }
}
is_deeply(\@violations, [], 'no lexical forward references');

done_testing();
