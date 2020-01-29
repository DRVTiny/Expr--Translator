package Expr::Translator;
use 5.16.1;
use strict;
use warnings;
use boolean;

use constant KNOWN_EXTRA_PARS => qw/debug/;
use List::Util qw(pairmap);
use Scalar::Util qw(blessed refaddr);
use Ref::Util qw(is_globref is_plain_arrayref is_arrayref);
use Data::Dumper;
use Carp qw(confess);

use enum qw(:STATE_ COLLECT_LEXEM SKIP_SPACES);

# Function Descriptor element
use enum qw(:FD_ ID NARGS PRIO ETYPE EXPR);
# Function Evaluation element
use enum qw(:FE_ SUB TYPE);
# sexpr_frag is [FUNC_ID, ARG_0, ARG_1 .. ARG_N]
use constant SEXPR_FUNC => 0;

use enum qw(:ETYPE_ ANY BOOLEAN);
# used in constructor
use enum qw(:E_ CTX_TYPE CTX_PROPS EVAL_FUN CHECK);

my (@code2fn, %fn2pn, @fn2res);

BEGIN {
    my @known_fns = (
        #  FUNCTION	  NARGS PRIO	IS_BOOL?	EXPR
            'OR' 	=> [2, 	1,	1, 		'%s or %s'	],
            'AND' 	=> [2, 	2,	1,             	'%s and %s'	],
            'NOT' 	=> [1, 	3,	1,		'! (%s)'	],
            '='         => [1,  0,      0,		'%s'		],
            '(' 	=> [0, 	0],
            ')' 	=> [0, 	0],
    );
    my $calc_op = <<'CODE';
        is_arrayref( $sym = $sexpr_frag->[++$op_i] )
            ? do { push @_, $sym; &{$fn2res[$sym->[0]][FE_SUB]} }
            : $self->eval_symbol($context, $sym, $fn2res[$sexpr_frag->[SEXPR_FUNC]][FE_TYPE])
CODE

    my $tmpl_sub = <<'CODE';
    sub {
        my ($self, $context) = @_;
#        print 'F_STACK:' . Dumper \@_;
        my $sexpr_frag = $_[-1];
        my $op_i = 0;
        my $sym;
        my $result = ( {{FUNC_EXPR}} );
        pop @_;
        $result
    }
CODE
    
    %fn2pn = do {
            my $c = 0;
            pairmap {
                push @code2fn, $a;
                my $fd = [$c++, @{$b}[(FD_NARGS - 1)..(FD_PRIO - 1)]];
                $#{$b} > 1 and push @fn2res, [
                    eval( $tmpl_sub =~ s<\{\{FUNC_EXPR\}\}>[ $b->[FD_EXPR - 1] =~ s/%s/${calc_op}/gr ]re ),
                    $b->[FD_ETYPE - 1],
                ];
                ( $a => $fd )
            } @known_fns
    };
}

sub new {
    my ($class, $equ, $how2eval, %pars) = @_;
    
    my %edef = 
    map {
        my ($etype, $econf) = each $how2eval;
        my ($ctxClass, $ctxProps) = @{$econf}{qw/ctx_type pass/};
        $ctxProps = [$ctxProps] unless is_plain_arrayref($ctxProps);
        $ctxClass->can($_) or die "$ctxClass cant do <<$_>>" for @{$ctxProps};
        ($etype => [$ctxClass, $ctxProps, $econf->{'fn'}])
    } 1..keys $how2eval;
    
    my $n_expr;    
    my $rxSymDef = sprintf q<^([a-zA-Z][a-zA-Z0-9_\-]*)\s*=\s*(%s):\s*(.+?)\s*$>, join('|', keys $how2eval);
    $rxSymDef = qr($rxSymDef);
    my %symbols = map {
        /^=\s*(.+)$/
            ? do {
                $n_expr = '= ' . $1;
                ()
              }
            : /${rxSymDef}/
                ? ($1 => [@{$edef{$2}}, $3])
                : ()
    } 
        grep !/^\s*(?:#.*)?$/,
             is_globref($equ) ? (<$equ>) : is_plain_arrayref($equ) ? @{$equ} : split /\r?\n/ => $equ;
    
    my $inst = 
        bless +{
                'sym_table' => \%symbols,
                'n_expr' => $n_expr,
                map { exists($pars{$_}) ? ($_ => $pars{$_}) : () } KNOWN_EXTRA_PARS()
        }, ref($class) || $class;
    defined( $n_expr ) or die 'evaluable final expression not found in passed string';
    $inst->{'s_expr'} = $inst->to_sexpr($n_expr, $pars{'debug'});
    $inst
}

sub to_sexpr {
    state $rxStopSymbols = qr<[()\s]>;
    my ($self, $s, $flDebug) = @_;
    my $symTable = $self->{'sym_table'};
    my (@lx_s, @fn_s);
    my $fdLeftBrck = $fn2pn{'('};
    my $fcLeftBrck = $fdLeftBrck->[FD_ID];
    my $state = STATE_COLLECT_LEXEM;
    my $p = -1;
    my $lxm = '';
    my $ls = length($s);
    
    while ( ++$p < $ls ) {
        my $l = substr($s, $p, 1);
        if ($state == STATE_COLLECT_LEXEM) {
            if ($l =~ $rxStopSymbols and length($lxm)) {
                say "Found lexem: $lxm" if $flDebug;
                if ( my $fd = $fn2pn{uc $lxm} ) {
                    say 'lexem classified as function' if $flDebug;
                    my $prio = $fd->[FD_PRIO];
                    while ( @fn_s and (my ($fc, $n_args, undef) = @{$fn_s[-1]})[FD_PRIO] > $prio ) {
                        scalar(@lx_s) < $n_args and die sprintf "not enough operands for %s, near %d at %s\n", $code2fn[$fc], $p, $s;
                        push @lx_s, [$fc, splice(@lx_s, -$n_args, $n_args, ())];
                        pop @fn_s;
                    }
                    push @fn_s, $fd;
                } else {
                    exists( $symTable->{$lxm} ) or die sprintf 'Symbol %s was not defined', $lxm;
                    say 'lexem classified as operand' if $flDebug;
                    push @lx_s, $lxm
                }
                $lxm = '';
            }
            
            if ( $l eq '(' ) {
                push @fn_s, $fdLeftBrck;
            } elsif ( $l eq ')' ) {
                while (@fn_s and (my ($fc, $n_args) = @{pop @fn_s})[FD_ID] != $fcLeftBrck) {
                    scalar(@lx_s) < $n_args and die sprintf "not enough operands for %s, near %d\n", $code2fn[$fc], $p;
                    push @lx_s, [$fc, splice(@lx_s, -$n_args, $n_args, ())]
                }
            } elsif ($l eq ' ' or $l eq "\t") {
                $state = STATE_SKIP_SPACES
            } else {
                $lxm .= $l
            }
        } elsif ($state == STATE_SKIP_SPACES) {
            unless ($l eq ' ' or $l eq "\t") {
                $p--;
                $state = STATE_COLLECT_LEXEM
            } 
        }
    }
    
    push @lx_s, $lxm if length($lxm);
    print Dumper {'lx_s' => \@lx_s, 'fn_s' => \@fn_s} if $flDebug;
    while (@fn_s and my ($fc, $n_args) = @{pop @fn_s}) {
        scalar(@lx_s) < $n_args and die sprintf "not enough operands for %s, near %d", $code2fn[$fc], $p;
        push @lx_s, [$fc, splice(@lx_s, -$n_args, $n_args, ())]
    }
    $#lx_s and die 'syntax error: operands without operator found';
    
    $lx_s[0]
}

sub print_sexpr {
    eval { Devel::Trace::trace('off') };
    my $c = 0;
    my $r = '(' . join(', ' => map is_plain_arrayref($_) ? print_sexpr($_) :  $c++ ? "'" . $_ . "'" : $code2fn[$_], @{is_plain_arrayref($_[0]) ? $_[0] : $_[0]->{'s_expr'}} ) . ')';
    eval { Devel::Trace::trace('on') };
    $r
}

sub eval_symbol {
    my ($self, $context, $symbol, $eval_type) = @_;
#    print Dumper {'SYMBOL' => $symbol};
    my $sym_def = $self->{'sym_table'}{$symbol};
    ( blessed($context) and $context->isa($sym_def->[E_CTX_TYPE]) )
        or confess sprintf 'context of type %s is not acceptable here', ref($context);
    # passing to eval function: 
    # 1.	check_definition, like net:/^10\,24[35]\./
    # 2. 	property values of $context object
    $self->{'sym_cache'}{refaddr $context}{$symbol} //=
    do {
        my $result = $sym_def->[E_EVAL_FUN]->(
            $sym_def->[E_CHECK],
            map $context->$_, @{$sym_def->[E_CTX_PROPS]}
        );
        $eval_type == ETYPE_BOOLEAN ? $result ? true : false : $result
    }
}

sub calc_sexpr_for { 		# for some $context
    my ($self, $context) = @_;
    $self->{'sym_cache'}{refaddr $context} = {};
    $#_ > 1 or push @_, $self->{'s_expr'};
#   print Dumper {"A" => $_[-1][0], "B" => \@fn2res,"C"=>$fn2res[$_[-1][0]]};
    my $result = &{$fn2res[$_[-1][0]][FE_SUB]};
    delete $self->{'sym_cache'}{refaddr $context};
    $result
}

1;
