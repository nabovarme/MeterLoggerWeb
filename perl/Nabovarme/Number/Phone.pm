package Nabovarme::Number::Phone;

use strict;
use warnings;
use Number::Phone::Lib;

sub new {
	my ($class, $input) = @_;

	return unless defined $input;

	# strip leading/trailing whitespace
	$input =~ s/^\s+|\s+$//g;

	# If it starts with 00 followed by digits, convert 00 to + for Number::Phone compatibility
	if ($input =~ /^00(\d+)/) {
		$input = '+' . $1;
	}
	# If it is exactly 8 digits and does not start with + or 00, assume it's a local Danish number
	elsif ($input =~ /^\d{8}$/ && $input !~ /^\+/) {
		$input = '+45' . $input;
	}

	my $obj = eval { Number::Phone::Lib->new($input) };
	return unless $obj && $obj->is_valid;

	return bless { obj => $obj }, $class;
}

sub is_valid {
	my $self = shift;
	return $self->{obj}->is_valid;
}

sub country {
	my $self = shift;
	return $self->{obj}->country_code;
}

# ✔ E.164 = library canonical output
sub e164 {
	my $self = shift;

	my $val = $self->{obj}->format;

	return unless defined $val;

	$val =~ s/\s+//g;

	return $val;
}

# ✔ DB format (fully normalized)
sub compact {
	my $self = shift;

	my $cc = $self->country;
	return unless defined $cc;

	my $raw = eval { $self->{obj}->format_using('Raw') }
		// $self->{obj}->format;

	return unless defined $raw;

	$raw =~ s/\D//g;

	return '+' . $cc . $raw;
}

# ✔ Standard international format with 00 prefix instead of +
sub international {
	my $self = shift;

	my $val = $self->compact;
	return unless defined $val;

	$val =~ s/^\+/00/;

	return $val;
}

1;