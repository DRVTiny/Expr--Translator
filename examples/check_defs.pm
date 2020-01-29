{
    'net' => +{
        'prio' => 10,
        'ctx_type' => 'Host',
        'pass'  => 'ip',
        'fn'    => sub {
            defined($_[0]) or die 'Expression is empty';
            given ( substr($_[0], 0, 1) ) {
                when (/^\d$/) {
                    subnet_matcher(split /,\s*/, $_[0])->($_[1]);
                };
                when ('/') {
                    &check_by_rx
                };
                default {
                    die 'Unknown expression format';
                };
            }
        },
    },
    'host' => +{
        'prio'  => 0,
        'ctx_type' => 'Host',
        'pass'  => 'fqdn',
        'fn'    => sub {
            given ( substr($_[0], 0, 1) ) {
                &check_by_rx when ('/');
                default { die 'Unknown expression format: ' . $_[0] };
            }
        }
    },
    'sub' => +{
        'prio'  => 100,
        'ctx_type' => 'Host',
        'pass'  => [qw/fqdn ip/],
        'fn'    => sub {
            my $expr = shift;
            $expr =~ /^\{(.+)\}\s*$/ or die 'free-matching-by-custom-code must be defined as "sub:{ CODE }"';
            my $res = eval "&{sub { $1 }}";
            defined($@) and length($@) and die "failed to eval user-defined code: $@\n";
            $res;
        }
    },
};
