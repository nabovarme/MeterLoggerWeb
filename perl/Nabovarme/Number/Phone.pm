package Nabovarme::Number::Phone;

use strict;
use warnings;
use Number::Phone::Lib;

sub new {
	my ($class, $input) = @_;

	return unless defined $input;

	# Strip leading/trailing whitespace and inner spaces/hyphens
	$input =~ s/^\s+|\s+$//g;
	$input =~ s/[- ]//g;

	# 1. Standardize 00 prefix into international '+' formatting
	if ($input =~ /^00(\d+)/) {
		$input = '+' . $1;
	}

	# 2. Fix 10-digit raw numbers starting with 45 but missing '+' (e.g., "4520291699")
	if ($input =~ /^45\d{8}$/) {
		$input = '+' . $input;
	}
	# 3. If it is exactly 8 digits, safely assume it's a local Danish number
	elsif ($input =~ /^\d{8}$/) {
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
	return $self->{obj}->format;
}

# ✔ DB format (fully normalized, no double country codes)
sub compact {
	my $self = shift;

	# Number::Phone's format() method natively returns E.164 (e.g., "+4520291699")
	my $raw = $self->{obj}->format;
	return unless defined $raw;

	# Clean up any remaining formatting artifacts from the underlying library representation
	$raw =~ s/[^\d+]//g; # Keep only digits and the leading plus symbol

	# If the library output lacks a leading '+', safely prepend it
	if ($raw !~ /^\+/) {
		$raw = '+' . $raw;
	}

	return $raw;
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
