package Nabovarme::ConditionEvaluator;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(evaluate);

# ==================================================
# PUBLIC API
# ==================================================
sub evaluate {
	my ($expr) = @_;

	my $out = {
		result  => 0,
		error   => undef,
		warning => undef,
		rpn     => undef,
	};

	return _fail($out, "undef expression") unless defined $expr;

	$expr =~ s/\s+//g;

	my ($tokens, $err) = _tokenize($expr);
	return _fail($out, $err) if $err;

	my ($rpn_ref, $err2) = _to_rpn($tokens);
	return _fail($out, $err2) if $err2;

	$out->{rpn} = $rpn_ref;

	my ($result, $warn) = _eval_rpn($rpn_ref);

	$out->{result}  = $result ? 1 : 0;
	$out->{warning} = $warn if $warn;

	return $out;
}

# ==================================================
# TOKENIZER
# ==================================================
sub _tokenize {
	my ($expr) = @_;

	my @tokens;

	while ($expr ne '') {

		# numbers
		if ($expr =~ s/^([-]?\d+(?:\.\d+)?)//) {
			push @tokens, $1;
			next;
		}

		# multi-char operators
		if ($expr =~ s/^(>=|<=|==|!=|&&|\|\|)//) {
			push @tokens, $1;
			next;
		}

		# single-char tokens
		if ($expr =~ s/^([><()])//) {
			push @tokens, $1;
			next;
		}

		return (undef, "Invalid token near: $expr");
	}

	return (\@tokens, undef);
}

# ==================================================
# PRECEDENCE
# ==================================================
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

# ==================================================
# SHUNTING YARD (INFIX -> RPN)
# ==================================================
sub _to_rpn {
	my ($tokens) = @_;

	my @output;
	my @stack;

	for my $t (@$tokens) {

		# number
		if ($t =~ /^\d/) {
			push @output, $t;
			next;
		}

		# operator
		if (exists $PREC{$t}) {

			while (@stack) {
				my $top = $stack[-1];

				last if $top eq '(';
				last if $PREC{$top} < $PREC{$t};

				push @output, pop @stack;
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
			my $found_paren = 0;

			while (@stack) {
				my $op = pop @stack;

				if ($op eq '(') {
					$found_paren = 1;
					last;
				}

				push @output, $op;
			}

			return (undef, "mismatched parentheses") unless $found_paren;
			next;
		}
	}

	# flush stack correctly (NO reverse!)
	while (@stack) {
		my $op = pop @stack;

		return (undef, "mismatched parentheses") if $op eq '(';

		push @output, $op;
	}

	return (\@output, undef);
}

# ==================================================
# RPN EVALUATOR
# ==================================================
sub _eval_rpn {
	my ($rpn) = @_;

	my @stack;

	for my $t (@$rpn) {

		# number
		if ($t =~ /^\d/) {
			push @stack, 0 + $t;
			next;
		}

		my $b = pop @stack;
		my $a = pop @stack;

		return (0, "stack underflow in expression") unless defined $a && defined $b;

		push @stack, _apply($a, $t, $b);
	}

	return (0, "invalid expression stack") if @stack != 1;

	return (pop @stack ? 1 : 0, undef);
}

# ==================================================
# OPERATORS
# ==================================================
sub _apply {
	my ($a, $op, $b) = @_;

	return 0 unless defined $a && defined $b;

	return ($a && $b) ? 1 : 0 if $op eq '&&';
	return ($a || $b) ? 1 : 0 if $op eq '||';

	return ($a >  $b) ? 1 : 0 if $op eq '>';
	return ($a <  $b) ? 1 : 0 if $op eq '<';
	return ($a >= $b) ? 1 : 0 if $op eq '>=';
	return ($a <= $b) ? 1 : 0 if $op eq '<=';
	return ($a == $b) ? 1 : 0 if $op eq '==';
	return ($a != $b) ? 1 : 0 if $op eq '!=';

	return 0;
}

# ==================================================
# ERROR HANDLING
# ==================================================
sub _fail {
	my ($out, $msg) = @_;

	$out->{error}  = $msg;
	$out->{result} = 0;

	return $out;
}

1;
