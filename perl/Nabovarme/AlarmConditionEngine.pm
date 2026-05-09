package Nabovarme::AlarmConditionEngine;

use strict;
use warnings;
use Marpa::R2;

# ==================================================
# PUBLIC API
# ==================================================
sub evaluate {
	my ($expr, $alarm) = @_;

	my $tokens = _lex($expr);

	my $grammar = _grammar();

	my $recce = Marpa::R2::Recognizer->new({
		grammar => $grammar,
		semantics_package => 'Nabovarme::AlarmConditionEngine::Semantics'
	});

	$recce->read($tokens);

	my $value = Marpa::R2::Value->new(
		grammar => $grammar,
		recognizer => $recce,
		semantics_package => 'Nabovarme::AlarmConditionEngine::Semantics'
	);

	return $value->value($alarm);
}

# ==================================================
# LEXER (turn expression into tokens)
# ==================================================
sub _lex {
	my ($expr) = @_;

	my @tokens;

	while ($expr =~ /\G\s*(\d+(?:\.\d+)?|\$?\w+|>=|<=|==|!=|&&|\|\||[()<>+\-*\/])\s*/gc) {
		push @tokens, $1;
	}

	return \@tokens;
}

# ==================================================
# GRAMMAR (Marpa SLIF format - CORRECT)
# ==================================================
my $grammar;

sub _grammar {
	return $grammar if $grammar;

	$grammar = Marpa::R2::Grammar->new({
		start => 'Expression',

		rules => [
			{ lhs => 'Expression', rhs => ['Expression', '||', 'Term'] },
			{ lhs => 'Expression', rhs => ['Term'] },

			{ lhs => 'Term', rhs => ['Term', '&&', 'Factor'] },
			{ lhs => 'Term', rhs => ['Factor'] },

			{ lhs => 'Factor', rhs => ['(', 'Expression', ')'] },
			{ lhs => 'Factor', rhs => ['Comparison'] },
			{ lhs => 'Factor', rhs => ['Value'] },

			{ lhs => 'Comparison', rhs => ['Value', 'COMP', 'Value'] },
		]
	});

	$grammar->precompute();
	return $grammar;
}

1;

# ==================================================
# SEMANTICS (evaluation logic)
# ==================================================
package Nabovarme::AlarmConditionEngine::Semantics;

use strict;
use warnings;

sub Value {
	my ($v, $alarm) = @_;

	# number
	return $v if defined $v && $v =~ /^\d+(\.\d+)?$/;

	# variable ($flow -> resolve_var(flow))
	$v =~ s/^\$// if defined $v;
	return main::resolve_var($v, $alarm);
}

sub Comparison {
	my ($left, $op, $right) = @_;

	return $left >  $right if $op eq '>';
	return $left <  $right if $op eq '<';
	return $left >= $right if $op eq '>=';
	return $left <= $right if $op eq '<=';
	return $left == $right if $op eq '==';
	return $left != $right if $op eq '!=';

	return 0;
}

sub Factor {
	return $_[0];
}

sub Term {
	my ($l, $op, $r) = @_;

	return $l && $r if $op eq '&&';
	return $l || $r if $op eq '||';

	return $r;
}

sub Expression {
	return $_[0];
}

1;
