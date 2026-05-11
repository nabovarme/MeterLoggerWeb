package Nabovarme::ConditionEvaluator;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(evaluate);

# ----------------------------
# Public API
# ----------------------------
sub evaluate {
	my ($expr) = @_;

	return 0 unless defined $expr;

	$expr = _normalize($expr);

	my @tokens = _tokenize($expr);
	my @rpn	= _to_rpn(@tokens);

	return _eval_rpn(@rpn);
}

# ----------------------------
# Normalize expression
# ----------------------------
sub _normalize {
	my ($e) = @_;

	$e =~ s/\s+//g;

	return $e;
}

# ----------------------------
# Tokenizer
# ----------------------------
sub _tokenize {
	my ($expr) = @_;

	my @t;

	while ($expr ne '') {

		# numbers
		if ($expr =~ s/^(\d+(?:\.\d+)?)//) {
			push @t, $1;
			next;
		}

		# multi-char operators
		if ($expr =~ s/^(>=|<=|==|!=|&&|\|\|)//) {
			push @t, $1;
			next;
		}

		# single-char tokens
		if ($expr =~ s/^([><()])//) {
			push @t, $1;
			next;
		}

		die "Invalid token in expression near: [$expr]";
	}

	return @t;
}

# ----------------------------
# Precedence
# ----------------------------
my %PREC = (
	'||' => 1,
	'&&' => 2,
	'>'  => 3,
	'<'  => 3,
	'>=' => 3,
	'<=' => 3,
	'==' => 3,
	'!=' => 3,
);

# ----------------------------
# Shunting-yard: infix → RPN
# ----------------------------
sub _to_rpn {
	my @tokens = @_;

	my @out;
	my @stack;

	for my $t (@tokens) {

		# number
		if ($t =~ /^\d/) {
			push @out, $t;
			next;
		}

		# operator
		if (exists $PREC{$t}) {

			while (@stack) {
				my $top = $stack[-1];

				last if $top eq '(';
				last if $PREC{$top} < $PREC{$t};

				push @out, pop @stack;
			}

			push @stack, $t;
			next;
		}

		# (
		if ($t eq '(') {
			push @stack, $t;
			next;
		}

		# )
		if ($t eq ')') {
			while (@stack && $stack[-1] ne '(') {
				push @out, pop @stack;
			}

			pop @stack; # remove '('
			next;
		}
	}

	push @out, reverse @stack;

	return @out;
}

# ----------------------------
# RPN evaluator
# ----------------------------
sub _eval_rpn {
	my @stack;

	for my $t (@_) {

		# number
		if ($t =~ /^\d/) {
			push @stack, $t + 0;
			next;
		}

		my $b = pop @stack;
		my $a = pop @stack;

		my $r = _apply($a, $t, $b);

		push @stack, $r;
	}

	return pop @stack ? 1 : 0;
}

# ----------------------------
# Operator logic
# ----------------------------
sub _apply {
	my ($a, $op, $b) = @_;

	return 0 unless defined $a && defined $b;

	if ($op eq '&&') { return ($a && $b) ? 1 : 0; }
	if ($op eq '||') { return ($a || $b) ? 1 : 0; }

	if ($op eq '>')  { return ($a >  $b) ? 1 : 0; }
	if ($op eq '<')  { return ($a <  $b) ? 1 : 0; }
	if ($op eq '>=') { return ($a >= $b) ? 1 : 0; }
	if ($op eq '<=') { return ($a <= $b) ? 1 : 0; }
	if ($op eq '==') { return ($a == $b) ? 1 : 0; }
	if ($op eq '!=') { return ($a != $b) ? 1 : 0; }

	return 0;
}

1;