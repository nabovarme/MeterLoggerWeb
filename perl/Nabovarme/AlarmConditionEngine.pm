package Nabovarme::AlarmConditionEngine;

use strict;
use warnings;
use Marpa::R2;

sub evaluate {
    my ($expr) = @_;

    return 0 unless defined $expr;

    my $grammar = _grammar();

    my $slg = Marpa::R2::Scanless::G->new({ source => \$grammar });

    my $slr = Marpa::R2::Scanless::R->new({ grammar => $slg });

    $slr->read(\$expr);

    my $value_ref = $slr->value();

    return defined $value_ref ? $$value_ref : 0;
}

sub _grammar {

return <<'GRAMMAR';

:default ::= action => ::first

:start ::= Expression

# -------------------------
# EXPRESSION
# -------------------------
Expression ::= Expression OR Term   action => do_or
              | Term

Term ::= Term GT Factor             action => do_gt
        | Term LT Factor            action => do_lt
        | Term GE Factor            action => do_ge
        | Term LE Factor            action => do_le
        | Term EQ Factor            action => do_eq
        | Term NE Factor            action => do_ne
        | Factor

# -------------------------
# MATH
# -------------------------
Factor ::= Factor PLUS Value        action => do_add
          | Factor MINUS Value      action => do_sub
          | Value

Value ::= Value TIMES Atom          action => do_mul
        | Value DIV Atom            action => do_div
        | Atom

Atom ::= NUMBER
       | LPAREN Expression RPAREN

# -------------------------
# TERMINALS
# -------------------------
NUMBER  ~ [0-9]+ ('.' [0-9]+)?
VARIABLE ~ '$' [a-zA-Z_] [a-zA-Z0-9_]*

PLUS   ~ '+'
MINUS  ~ '-'
TIMES  ~ '*'
DIV    ~ '/'

GT     ~ '>'
LT     ~ '<'
GE     ~ '>='
LE     ~ '<='
EQ     ~ '=='
NE     ~ '!='

OR     ~ '||'

LPAREN ~ '('
RPAREN ~ ')'

:discard ~ whitespace
whitespace ~ [\s]+

GRAMMAR
}

# -------------------------
# ACTIONS
# -------------------------
sub do_or  { $_[1] || $_[3] ? 1 : 0 }

sub do_gt { $_[1] > $_[3] ? 1 : 0 }
sub do_lt { $_[1] < $_[3] ? 1 : 0 }
sub do_ge { $_[1] >= $_[3] ? 1 : 0 }
sub do_le { $_[1] <= $_[3] ? 1 : 0 }
sub do_eq { $_[1] == $_[3] ? 1 : 0 }
sub do_ne { $_[1] != $_[3] ? 1 : 0 }

sub do_add { $_[1] + $_[3] }
sub do_sub { $_[1] - $_[3] }
sub do_mul { $_[1] * $_[3] }
sub do_div { $_[3] ? $_[1] / $_[3] : 0 }

1;
