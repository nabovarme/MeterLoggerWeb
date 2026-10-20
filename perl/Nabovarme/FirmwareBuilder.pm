package Nabovarme::FirmwareBuilder;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(build_flags_from_sw_version);

# Translate the firmware version string into compiler flags matching Makefile specs.
sub build_flags_from_sw_version {
	my ($sw_version) = @_;
	return 'AP=1' unless defined $sw_version;

	# Extract the bracketed segment metadata if present.
	my $flags_segment = $sw_version;
	if ($sw_version =~ /\[(.*?)\]/) {
		$flags_segment = $1;
	}

	# Split on spaces or hyphens.
	my @tokens = split(/[\s\-]+/, $flags_segment);
	my @flags = ('AP=1');

	# Create a hash of all bare tokens for O(1) lookups.
	my %has_token = map { $_ => 1 } @tokens;

	# Helper for explicit FLAG=value overrides.
	my $get_explicit_val = sub {
		my ($key) = @_;
		my ($match) = grep { /^\Q$key\E=/ } @tokens;
		return $match ? (split(/=/, $match, 2))[1] : undef;
	};

	# 1. Core hardware protocol selectors.
	if (($get_explicit_val->('MC_66B') // '') eq '1'
		|| $has_token{'MC_66B'}
		|| $has_token{'MC_B'}
		|| ($has_token{'MC'} && $has_token{'B'})) {
		push @flags, 'MC_66B=1';
	}
	elsif (($get_explicit_val->('EN61107') // '') eq '1'
		|| $has_token{'EN61107'}
		|| $has_token{'MC'}) {
		push @flags, 'EN61107=1';
	}
	elsif (($get_explicit_val->('IMPULSE') // '') eq '1'
		|| $has_token{'IMPULSE'}) {
		push @flags, 'IMPULSE=1';
	}

	# 2. Logic overrides and modifiers.
	if (($get_explicit_val->('FLOW') // '') eq '1'
		|| $has_token{'FLOW'}
		|| $has_token{'FLOW_METER'}) {
		push @flags, 'FLOW_METER=1';
	}

	my $auto_close_val = $get_explicit_val->('AUTO_CLOSE');
	if ($has_token{'NO_AUTO_CLOSE'}
		|| (defined $auto_close_val && $auto_close_val eq '0')) {
		push @flags, 'AUTO_CLOSE=0';
	}

	if (($get_explicit_val->('NO_CRON') // '') eq '1'
		|| $has_token{'NO_CRON'}) {
		push @flags, 'NO_CRON=1';
	}

	if (($get_explicit_val->('DISABLE_LED') // '') eq '1'
		|| $has_token{'DISABLE_LED'}) {
		push @flags, 'DISABLE_LED=1';
	}

	# 3. Actuator configuration.
	my $thermo_no = $get_explicit_val->('THERMO_NO');
	if ($has_token{'THERMO_NO'}
		|| (defined $thermo_no && $thermo_no eq '1')) {
		push @flags, 'THERMO_NO=1';
	}
	elsif ($has_token{'THERMO_NC'}
		|| (defined $thermo_no && $thermo_no eq '0')) {
		push @flags, 'THERMO_NO=0';
	}

	if (($get_explicit_val->('THERMO_ON_AC_2') // '') eq '1'
		|| $has_token{'THERMO_ON_AC_2'}) {
		push @flags, 'THERMO_ON_AC_2=1';
	}

	if (($get_explicit_val->('LED_ON_AC') // '') eq '1'
		|| $has_token{'LED_ON_AC'}) {
		push @flags, 'LED_ON_AC=1';
	}

	if (($get_explicit_val->('AC_TEST') // '') eq '1'
		|| $has_token{'AC_TEST'}) {
		push @flags, 'AC_TEST=1';
	}

	# 4. Diagnostics and trace variables.
	my $wants_debug =
		$has_token{'DEBUG'}
		|| (($get_explicit_val->('DEBUG') // '') eq '1');

	my $wants_debug_no_meter =
		$has_token{'DEBUG_NO_METER'}
		|| $has_token{'NO_METER'}
		|| (($get_explicit_val->('DEBUG_NO_METER') // '') eq '1')
		|| (($get_explicit_val->('NO_METER') // '') eq '1');

	if ($wants_debug_no_meter) {
		push @flags, 'DEBUG=1', 'DEBUG_NO_METER=1';
	}
	elsif ($wants_debug) {
		push @flags, 'DEBUG=1';
	}

	if (($get_explicit_val->('DEBUG_STACK_TRACE') // '') eq '1'
		|| $has_token{'DEBUG_STACK_TRACE'}) {
		push @flags, 'DEBUG_STACK_TRACE=1';
	}

	if (($get_explicit_val->('DEBUG_SHORT_WEB_CONFIG_TIME') // '') eq '1'
		|| $has_token{'DEBUG_SHORT_WEB_CONFIG_TIME'}) {
		push @flags, 'DEBUG_SHORT_WEB_CONFIG_TIME=1';
	}

	return join(' ', @flags);
}

1;
