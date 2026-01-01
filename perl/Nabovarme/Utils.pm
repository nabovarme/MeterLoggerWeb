package Nabovarme::Utils;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(floor);
use File::Basename;
use Net::SMTP;
use Email::MIME;
use Encode qw(encode decode is_utf8);

our @EXPORT = qw(
	rounded_duration
	send_notification
	log_info
	log_warn
	log_debug
	log_die
);

$| = 1;  # Autoflush STDOUT

# Make sure STDOUT and STDERR handles UTF-8
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

# Get the basename of the script, without path or .pl extension
my $script_name = basename($0, ".pl");

# ----------------------------
# Format seconds into readable duration
# ----------------------------
sub rounded_duration {
	my $seconds = shift;
	return '∞' unless defined $seconds;

	my $is_negative = $seconds < 0;
	$seconds = abs($seconds);

	my $result;
	if ($seconds >= 86400) {
		my $days = int(($seconds + 43200) / 86400);
		$result = $days == 1 ? "1 day" : "$days days";
	}
	else {
		my $hours = int(($seconds + 1800) / 3600);
		$result = $hours == 1 ? "1 hour" : "$hours hours";
	}

	return $is_negative ? "$result ago" : $result;
}

# ----------------------------
# Sends SMS, returns 1 on success, 0 on failure
# ----------------------------
sub send_notification {
	my ($sms_number, $message) = @_;
	return 0 unless $sms_number && $message;

	eval {
		unless (is_utf8($message)) {
			log_warn(" Message is NOT flagged as UTF-8 internally, decoding...");
			$message = decode('UTF-8', $message);
		} else {
			log_warn(" Message is already flagged as UTF-8 internally");
		}

		my $email = Email::MIME->create(
			header_str => [
				From    => 'meterlogger@meterlogger',
				To      => '45' . $sms_number . '@meterlogger',
				Subject => $message,
			],
			attributes => {
				encoding      => 'quoted-printable',
				charset       => 'UTF-8',
				content_type  => 'text/plain',
			},
			body => '',
		);

		my $smtp = Net::SMTP->new('postfix', Timeout => 10);
		unless ($smtp) {
			log_warn("Cannot connect to SMTP server");
			return 0;
		}

		$smtp->mail('meterlogger')
			|| log_warn("SMTP MAIL FROM failed: ".$smtp->message());

		$smtp->to("45$sms_number\@meterlogger")
			|| log_warn("SMTP RCPT TO failed: ".$smtp->message());

		$smtp->data()
			|| log_warn("SMTP DATA failed: ".$smtp->message());

		$smtp->datasend($email->as_string)
			|| log_warn("SMTP DATASEND failed: ".$smtp->message());

		$smtp->dataend()
			|| log_warn("SMTP DATAEND failed: ".$smtp->message());

		$smtp->quit()
			|| log_warn("SMTP QUIT failed: ".$smtp->message());

		log_info("SMS sent to $sms_number");
	};

	if($@) {
		log_warn("Failed to send SMS to $sms_number: $@");
		return 0;
	}

	return 1;
}

# ----------------------------
# Logging functions
# ----------------------------
sub log_info {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDOUT, '', \@msgs, $opts);
}

sub log_warn {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDERR, 'WARN', \@msgs, $opts);
}

sub log_debug {
	return unless ($ENV{ENABLE_DEBUG} || '') =~ /^(1|true|yes)$/i;
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}
	_log_message(\*STDOUT, 'DEBUG', \@msgs, $opts);
}

sub log_die {
	my (@msgs) = @_;
	my $opts = {};
	if (ref $msgs[-1] eq 'HASH') {
		$opts = pop @msgs;
	}

	# Log as WARN first
	_log_message(\*STDERR, 'WARN', \@msgs, $opts);

	# Exit immediately with joined messages
	my $text = join('', map { defined $_ ? $_ : '' } @msgs);
	chomp($text);
	die "[" . ($opts->{no_script_name} ? '' : $script_name) . "] [WARN] $text\n";
}

sub _log_message {
	my ($fh, $level, $msgs_ref, $opts) = @_;

	my $disable_tag        = $opts->{-no_tag};
	my $disable_script     = $opts->{-no_script_name};
	my $custom_tag         = $opts->{-custom_tag};          # e.g. "SMS"
	my $custom_script_name = $opts->{-custom_script_name};  # e.g. "my_script.pl"

	# Determine caller info
	my ($caller_package, $caller_file, $caller_line) = caller(1);  # caller of log_* function
	my $module_name = ($caller_package && $caller_package ne 'main') ? $caller_package : undef;

	my $script_display = $disable_script ? '' : ($custom_script_name || $script_name);

	# Determine prefix for levels like WARN/DEBUG
	my $prefix = (!$disable_tag && $level) ? "[$level] " : '';

	foreach my $msg (@$msgs_ref) {
		my $text = defined $msg ? $msg : '';
		chomp($text);

		# Determine output style
		my $line;
		if (defined $custom_tag) {
			# Custom tag is always separate brackets
			my @parts;
			push @parts, "[$script_display]" if $script_display;
			push @parts, "[$custom_tag]";
			my $line_prefix = join(' ', @parts);
			$line = "$line_prefix $prefix$text";
		} elsif ($module_name && $caller_package eq $module_name && !$disable_script) {
			# Called from another function in the same module → arrow style
			$line = "[$script_display->$module_name] $prefix$text";
		} elsif ($module_name && !$disable_script) {
			# External module → separate brackets
			$line = "[$script_display] [$module_name] $prefix$text";
		} elsif ($module_name) {
			$line = "[$module_name] $prefix$text";
		} elsif (!$disable_script) {
			$line = "[$script_display] $prefix$text";
		} else {
			$line = "$prefix$text";
		}

		print $fh "$line\n";
	}
}


1;

__END__
