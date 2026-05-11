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
		rpn	 => undef,
	};

	return _fail($out, "undef expression") unless defined $expr;

	$expr =~ s/\s+//g;

	my ($tokens, $err) = _tokenize($expr);
	return _fail($out, $err) if $err;

	my @rpn = _to_rpn(@$tokens);
	$out->{rpn} = \@rpn;   # optional debug trace

	my ($result, $warn) = _eval_rpn(@rpn);

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
		if ($expr =~ s/^(\d+(?:\.\d+)?)//) {
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
# OPERATOR PRECEDENCE
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
# SHUNTING-YARD (INFIX → RPN)
# ==================================================
sub _to_rpn {
	my @tokens = @_;

	my @output;
	my @stack;

	for my $t (@tokens) {

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
			while (@stack && $stack[-1] ne '(') {
				push @output, pop @stack;
			}

			pop @stack; # remove '('
			next;
		}
	}

	push @output, reverse @stack;

	return @output;
}

# ==================================================
# RPN EVALUATOR
# ==================================================
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

		unless (defined $a && defined $b) {
			return (0, "stack underflow in expression");
		}

		my $r = _apply($a, $t, $b);

		push @stack, $r;
	}

	return (pop @stack ? 1 : 0, undef);
}

# ==================================================
# OPERATORS
# ==================================================
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
