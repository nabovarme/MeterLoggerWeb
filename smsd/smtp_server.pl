#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Carp;
use Encode qw(encode decode is_utf8);
use Email::Simple;
use Email::MIME;
use Data::Dumper;
use File::Basename;

use Net::Server::Mail::SMTP;
use IO::Socket::INET;
use Net::SMTP;

use LWP::UserAgent;
use HTTP::Cookies;
use JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Spec;
use Time::HiRes qw(sleep);
use threads;
use threads::shared;

use Nabovarme::Db;
use Nabovarme::Utils;

use constant USER  => 'smsd';
use constant GROUP => 'smsd';

$| = 1;  # Autoflush STDOUT

$Data::Dumper::Useqq = 0;
$Data::Dumper::Terse = 1;
$Data::Dumper::Quotekeys = 0;

# Get the script basename
my $script_name = basename($0, ".pl");

# --- Connect to database ---
my $dbh = Nabovarme::Db->my_connect;
log_die("DB connection failed", {-no_script_name => 1}) unless $dbh;
log_info("Connected to DB for SMS logging", {-no_script_name => 1});

# --- Dry run mode ---
my $dry_run = ($ENV{SMSD_DRY_RUN} || '') =~ /^(1|true|yes)$/i;

# --- Read configuration from environment ---
my $router    = $ENV{RUT901_ROUTER_IP}   or log_die("Missing RUT901_ROUTER_IP env variable", {-no_script_name => 1, -custom_tag => 'SMS' });
my $username  = $ENV{RUT901_ROUTER_USER} or log_die("Missing RUT901_ROUTER_USER env variable", {-no_script_name => 1, -custom_tag => 'SMS' });
my $password  = $ENV{RUT901_ROUTER_PASS} || "";

# --- SMTP configuration from environment ---
my $smtp_host  = $ENV{SMTP_HOST}     or log_die("Missing SMTP_HOST env variable", {-no_script_name => 1, -custom_tag => 'SMTP' });
my $smtp_port  = $ENV{SMTP_PORT}     || 587;
my $smtp_user  = $ENV{SMTP_USER}     || '';
my $smtp_pass  = $ENV{SMTP_PASSWORD} || '';
my $from_email = $ENV{FROM_EMAIL}    or log_die("Missing FROM_EMAIL env variable", {-no_script_name => 1, -custom_tag => 'SMTP' });
my $to_email   = $ENV{TO_EMAIL}      or log_die("Missing TO_EMAIL env variable", {-no_script_name => 1, -custom_tag => 'SMTP' });

my @to_list = split /[\s,]+/, $to_email;

# --- Global flag to prevent concurrent send_sms/read_sms ---
my $sms_busy :shared = 0;
my %sent_sms;

# --- Shared globals to track the current active session for logout ---
my $current_qsess :shared;   # current router session ID
my $current_ua;               # current LWP::UserAgent

# --- Handle Docker / SIGTERM / Ctrl+C ---
$SIG{INT}  = \&cleanup_and_exit;
$SIG{TERM} = \&cleanup_and_exit;

sub cleanup_and_exit {
	log_info("Caught termination signal, attempting logout...", {-no_script_name => 1, -custom_tag => 'EXIT' });

	if ($current_qsess && $current_ua) {
		eval {
			my $logout_resp = $current_ua->post(
				"https://$router/logout",
				Authorization => "Bearer $current_qsess"
			);
			log_info($logout_resp->is_success ? "Logout successful" : "Logout failed: " . $logout_resp->status_line,
				{-no_script_name => 1, -custom_tag => 'EXIT' });
		};
		if ($@) {
			log_warn("Logout during signal handling failed: $@", {-no_script_name => 1, -custom_tag => 'EXIT' });
		}
	}

	# Unlock SMS if it was busy
	{
		lock($sms_busy);
		$sms_busy = 0;
	}

	exit 0;
}

# --- Initialize HTTP client ---
sub make_ua {
	my $ua = LWP::UserAgent->new(
		agent   => "Mozilla/5.0",
		timeout => 30,
		ssl_opts => {
			verify_hostname => 0,   # ignore self-signed certificate host mismatch
			SSL_verify_mode => 0x00 # do not verify SSL certificates
		}
	);

	return $ua;
}

# --- Save SMS to db ---
sub log_sms_to_db {
	my ($dbh_thread, $direction, $phone, $message) = @_;
	$dbh_thread ||= $dbh;
	$phone   ||= '';
	$message ||= '';

	return unless $direction;  # 'sent' or 'received'

	eval {
		my $sth = $dbh_thread->prepare(
			"INSERT INTO sms_messages (direction, phone, message, unix_time)
			 VALUES (?, ?, ?, ?)"
		);
		$sth->execute($direction, $phone, $message, time());
		log_info("log_sms_to_db called for $phone, direction: $direction", {-no_script_name => 1, -custom_tag => 'SMS'});
	};
	if ($@) {
		log_warn("Failed log_sms_to_db for $phone, direction: $direction, error=$@", {-no_script_name => 1, -custom_tag => 'SMS'});
	}
}

# --- Send SMS via RUT901 API ---
sub send_sms {
	my ($phone, $message) = @_;

	# Lock other SMS actions
	{
		lock($sms_busy);
		return 0 if $sms_busy;
		$sms_busy = 1;
	}

	unless ($phone && $message) {
		{
			lock($sms_busy);
			$sms_busy = 0;
		}
		log_die("Missing phone or message", {-no_script_name => 1, -custom_tag => 'SMS OUT' });
	}

	if ($dry_run) {
		log_info("DRY RUN: send_sms called for $phone with message: $message", {-no_script_name => 1, -custom_tag => 'SMS OUT'});

		# Log to DB
		log_sms_to_db(
			$dbh,
			'sent',
			$phone,
			$message
		);
		{
			lock($sms_busy);
			$sms_busy = 0;
		}
		sleep 20;
		return 1;
	}

	my $ua = make_ua();

	# --- Login to RUT901 ---
	log_info("Logging in as $username", {-no_script_name => 1, -custom_tag => 'SMS OUT' });
	my $login_resp = $ua->post(
		"https://$router/api/login",
		Content_Type => "application/json",
		Content      => encode_json({ username => $username, password => $password })
	);

	unless ($login_resp->is_success) {
		my $resp_content = $login_resp->decoded_content // '';
		log_warn("❌ Login HTTP failed: " . $login_resp->status_line . " | Content: $resp_content",
			{-no_script_name => 1, -custom_tag => 'SMS OUT'});
		{
			lock($sms_busy);
			$sms_busy = 0;
		}
		log_die("Login failed", {-no_script_name => 1, -custom_tag => 'SMS OUT'});
	}

	# --- Extract token ---
	my $login_data = decode_json($login_resp->decoded_content);
	my $token = $login_data->{data}->{token} or log_die("No token returned from RUT901", {-no_script_name => 1, -custom_tag => 'SMS OUT' });

	# Track global session for signal handling
	{
		lock($current_qsess);
		$current_qsess = $token;
	}
	$current_ua = $ua;

	# --- Prepare SMS payload ---
	my $payload = {
		data => {
			number  => ($phone =~ /^\+/ ? $phone : '+' . $phone),
			message => $message,
			modem   => "1-1"
		}
	};

	# --- Send SMS ---
	log_info("Sending SMS to $phone", {-no_script_name => 1, -custom_tag => 'SMS OUT' });
	my $sms_resp = $ua->post(
		"https://$router/api/messages/actions/send",
		Content_Type  => "application/json",
		Authorization => "Bearer $token",
		Content       => encode_json($payload)
	);

	my $success = 0;

	# --- Check response ---
	if ($sms_resp->is_success) {

		my $resp_json = decode_json($sms_resp->decoded_content);

		if ($resp_json->{success}) {
			# --- Log success to DB ---
			log_sms_to_db($dbh, 'sent', $phone, $message);
			log_info("✔ SMS to $phone sent successfully", {-no_script_name => 1, -custom_tag => 'SMS OUT'});
			$success = 1;
		} else {
			# --- API-level failure ---
			my $error_msg = $resp_json->{errors}[0]{error} // 'Unknown error';
			log_warn("❌ SMS to $phone failed: $error_msg", {-no_script_name => 1, -custom_tag => 'SMS OUT'});
		}

	} else {
		# --- HTTP-level failure ---
		my $http_error = $sms_resp->status_line;
		my $resp_content = $sms_resp->decoded_content // '';
		log_warn("❌ HTTP request failed for SMS to $phone: $http_error | Content: $resp_content",
			{-no_script_name => 1, -custom_tag => 'SMS OUT'});
	}

	# --- Logout ---
	log_info("Logging out session $token", {-no_script_name => 1, -custom_tag => 'SMS OUT' });
	eval {
		my $logout_resp = $ua->post(
			"https://$router/logout",
			Authorization => "Bearer $token"
		);
		unless ($logout_resp->is_success) {
			my $resp_content = $logout_resp->decoded_content // '';
			log_warn("Logout failed: " . $logout_resp->status_line . " | Content: $resp_content",
				{-no_script_name => 1, -custom_tag => 'SMS OUT'});
		} else {
			log_info("Logout successful", {-no_script_name => 1, -custom_tag => 'SMS OUT'});
		}
	};

	# Clear global session after proper logout
	{
		lock($current_qsess);
		$current_qsess = undef;
	}
	$current_ua = undef;

	# Unlock SMS
	{
		lock($sms_busy);
		$sms_busy = 0;
	}

	return $success;
}

# --- Read SMS periodically ---
sub read_sms {
	my ($dbh_thread) = @_;

	# Lock other SMS actions
	{
		lock($sms_busy);
		return if $sms_busy;
		$sms_busy = 1;
	}

	my $ua = make_ua();

	eval {
		# --- Login ---
		log_info("Logging in for SMS read", {-no_script_name => 1, -custom_tag => 'SMS IN' });
		my $login_resp = $ua->post(
			"https://$router/api/login",
			Content_Type => "application/json",
			Content      => encode_json({ username => $username, password => $password })
		);

		my $login_data;
		if ($login_resp->is_success) {
			$login_data = decode_json($login_resp->decoded_content);

			# --- Check API-level login success ---
			unless ($login_data->{success}) {
				my $err = $login_data->{errors}[0]{error} // 'Unknown login error';
				log_warn("Login API error: $err", {-no_script_name => 1, -custom_tag => 'SMS IN'});
				die "Login API failed: $err";
			}

		} else {
			my $resp_content = $login_resp->decoded_content // '';
			log_warn("❌ SMS read login HTTP failed: " . $login_resp->status_line . " | Content: $resp_content",
				{-no_script_name => 1, -custom_tag => 'SMS IN'});
			die "SMS read login HTTP failed: " . $login_resp->status_line;
		}

		# --- Extract token ---
		my $token = $login_data->{data}->{token} or die "No token returned from login";

		# Track global session
		{
			lock($current_qsess);
			$current_qsess = $token;
		}
		$current_ua = $ua;

		# --- Fetch inbox ---
		log_info("Fetching inbox messages", {-no_script_name => 1, -custom_tag => 'SMS IN' });
		my $resp = $ua->get(
			"https://$router/api/messages/status",
			Authorization => "Bearer $token"
		);

		unless ($resp->is_success) {
			my $resp_content = $resp->decoded_content // '';
			log_warn("❌ SMS read HTTP failed: " . $resp->status_line . " | Content: $resp_content",
				{-no_script_name => 1, -custom_tag => 'SMS IN'});
			die "SMS read HTTP failed: " . $resp->status_line;
		}

		my $sms_list_json = decode_json($resp->decoded_content);
		my $sms_list = $sms_list_json->{data} || [];
		log_info("Received " . scalar(@$sms_list) . " messages", {-no_script_name => 1, -custom_tag => 'SMS IN' });

		my $incoming_dir = "/var/spool/sms/incoming";
		make_path($incoming_dir) unless -d $incoming_dir;

		for my $msg (@$sms_list) {
			my $phone   = $msg->{number}  || '';
			my $date    = $msg->{date}    || '';
			my $id      = $msg->{id}      || '';
			my $message = $msg->{message} || '';

			log_info("Processing message ID=$id", {-no_script_name => 1, -custom_tag => 'SMS IN' });
			log_info("\tFrom: $phone", {-no_script_name => 1, -custom_tag => 'SMS IN' });
			log_info("\tDate: $date", {-no_script_name => 1, -custom_tag => 'SMS IN' });
			log_info("\tMessage: $message", {-no_script_name => 1, -custom_tag => 'SMS IN' });

			# --- Delete message ---
			my $del_payload = { data => { ids => [$id] } };
			my $del_resp = $ua->post(
				"https://$router/api/messages/actions/remove_messages",
				Content_Type => "application/json",
				Authorization => "Bearer $token",
				Content      => encode_json($del_payload)
			);

			if ($del_resp->is_success) {
				log_info("Deleted message ID=$id successfully", 
					{-no_script_name => 1, -custom_tag => 'SMS IN' });
			} else {
				my $resp_content = $del_resp->decoded_content // '';
				log_warn("❌ DELETE FAILED for SMS ID=$id from $phone: " 
				         . $del_resp->status_line 
				         . " | Content: $resp_content",
				         {-no_script_name => 1, -custom_tag => 'SMS IN'});
				next;
			}

			# --- Log received message to DB ---
			log_sms_to_db(
				$dbh_thread,
				'received',
				$phone,
				$message
			);

			# Forward via email
			forward_sms_email($phone, $message);
		}

		# --- Logout ---
		log_info("Logging out session $token", {-no_script_name => 1, -custom_tag => 'SMS IN' });
		my $logout_resp = $ua->post(
			"https://$router/logout",
			Authorization => "Bearer $token"
		);
		unless ($logout_resp->is_success) {
			my $resp_content = $logout_resp->decoded_content // '';
			log_warn("Logout failed: " . $logout_resp->status_line . " | Content: $resp_content",
				{-no_script_name => 1, -custom_tag => 'SMS IN'});
		} else {
			log_info("Logout successful", {-no_script_name => 1, -custom_tag => 'SMS IN'});
		}

		# Clear global session after proper logout
		{
			lock($current_qsess);
			$current_qsess = undef;
		}
		$current_ua = undef;

		return $sms_list;
	};

	if ($@) {
		log_warn("Error in read_sms: $@", {-no_script_name => 1, -custom_tag => 'SMS IN' });
	}

	{
		lock($sms_busy);
		$sms_busy = 0;
	}
}

# --- Forward SMS via email ---
sub forward_sms_email {
	my ($phone, $message) = @_;
	return if $sent_sms{$message};

	eval {
		# Normalize line endings to CRLF for SMTP compliance
		$message =~ s/\r?\n/\r\n/g;

		# Encode UTF-8 flagged string to bytes
		my $utf8_text = encode('UTF-8', $message)
			or log_die("UTF-8 encode failed", {-no_script_name => 1, -custom_tag => 'SMTP' });

		# Create proper Email::MIME object
		my $email = Email::MIME->create(
			header_str => [
				From    => $smtp_user || $from_email,
				To      => join(", ", @to_list),
				Subject => "SMS from $phone",
			],
			attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
			body       => $utf8_text,
		) or log_die("Failed to create Email::MIME object", {-no_script_name => 1, -custom_tag => 'SMTP' });

		# Loop over each recipient and send individually
		foreach my $recipient (@to_list) {
			# Connect to SMTP server
			my $smtp = Net::SMTP->new(
				$smtp_host,
				Port            => $smtp_port,
				Timeout         => 20,
				Debug           => 0,
				SSL_verify_mode => 0,
			);

			unless ($smtp) {
				log_warn("SMTP connect failed for $recipient", {-no_script_name => 1, -custom_tag => 'SMTP' });
				next;
			}

			# Start TLS if using port 587
			eval { $smtp->starttls() } if $smtp_port == 587;

			# Authenticate if credentials provided
			if ($smtp_user && $smtp_pass) {
				unless ($smtp->auth($smtp_user, $smtp_pass)) {
					log_warn("SMTP auth failed for $recipient", {-no_script_name => 1, -custom_tag => 'SMTP' });
					$smtp->quit;
					next;
				}
			} else {
				log_warn("SMTP credentials not provided, skipping auth", {-no_script_name => 1, -custom_tag => 'SMTP' });
			}

			# Set sender and recipient
			$smtp->mail($smtp_user || $from_email) or log_die("SMTP MAIL FROM failed", {-no_script_name => 1, -custom_tag => 'SMTP' });
			$smtp->to($recipient) or log_die("SMTP RCPT TO failed for $recipient", {-no_script_name => 1, -custom_tag => 'SMTP' });

			$smtp->data() or log_die("SMTP DATA failed", {-no_script_name => 1, -custom_tag => 'SMTP' });
			$smtp->datasend($email->as_string) or log_die("SMTP DATASEND failed", {-no_script_name => 1, -custom_tag => 'SMTP' });
			$smtp->dataend() or log_die("SMTP DATAEND failed", {-no_script_name => 1, -custom_tag => 'SMTP' });

			# Close SMTP session
			$smtp->quit();

			log_info("Forwarded SMS from $phone to: $recipient", {-no_script_name => 1, -custom_tag => 'SMTP' });
		}

		# Mark as sent to avoid duplicate forwarding
		$sent_sms{$message} = 1;
	};

	log_warn("Failed to send email for SMS from $phone: $@", {-no_script_name => 1, -custom_tag => 'SMTP' }) if $@;
}

# --- Background thread to read SMS ---
unless ($dry_run) {
	threads->create(sub {
		# Each thread has its own DB connection
		my $dbh_thread = Nabovarme::Db->my_connect;
		log_die("DB connection failed in SMS thread", {-no_script_name => 1}) unless $dbh_thread;

		while (1) {
			read_sms($dbh_thread);
			sleep(10);
		}
	})->detach();
} else {
	log_info("DRY RUN: SMS reading thread skipped", {-no_script_name => 1, -custom_tag => 'SMS IN'});
}

# --- SMTP server ---
my $socket = IO::Socket::INET->new(
	LocalPort => 25,
	Listen    => 5,
	Proto     => 'tcp',
	Reuse     => 1,
) or log_die("Unable to bind port 25: $!", {-no_script_name => 1, -custom_tag => 'SMTP' });

log_info("SMS Gateway running on port 25...", {-no_script_name => 1, -custom_tag => 'SMTP' });

# Main loop: accept SMTP clients
while (my $client = $socket->accept()) {
	log_info("Accepted connection from " . $client->peerhost . ":" . $client->peerport, {-no_script_name => 1, -custom_tag => 'SMTP' });

	my $smtp = Net::Server::Mail::SMTP->new(socket => $client);

	$smtp->set_callback(RCPT => sub {
		my ($session, $rcpt) = @_;
		$rcpt =~ s/\D//g;
		$session->{_sms_to} = $rcpt;
		log_info("RCPT TO: $rcpt", {-no_script_name => 1, -custom_tag => 'SMTP' });
		return 1;
	});

	$smtp->set_callback(DATA => sub {
		my ($session, $data) = @_;

		# Parse email with MIME decoding
		my $mime = Email::MIME->new($data);

		# Extract subject
		my $subject = $mime->header('Subject') || '';

		# Extract decoded text/plain body
		my $body;
		for my $part ($mime->parts) {
			if (($part->content_type // '') =~ m{text/plain}i) {
				$body = $part->body_str;   # Handles base64 / quoted-printable automatically
				last;
			}
		}
		$body //= $mime->body;  # fallback if no parts

		# Combine subject + body
		my $message = join(" ", grep { defined $_ && length($_) } ($subject, $body));

		# Ensure Perl UTF-8
		unless (is_utf8($message)) {
			log_warn(" Message is NOT flagged as UTF-8 internally, decoding...", {-no_script_name => 1, -custom_tag => 'SMS OUT'});
			$message = decode('UTF-8', $message);
		} else {
			log_warn(" Message is already flagged as UTF-8 internally", {-no_script_name => 1, -custom_tag => 'SMS OUT'});
		}

		my $dest = $session->{_sms_to};

		log_info("Sending SMS to $dest ...", {-no_script_name => 1, -custom_tag => 'SMS OUT' });
		my $ok = send_sms($dest, $message);

		if ($ok) {
			log_info("✔ SMS to $dest sent successfully", {-no_script_name => 1, -custom_tag => 'SMS OUT' });
			return 1;
		} else {
			log_warn("❌ SMS to $dest failed: $@", {-no_script_name => 1, -custom_tag => 'SMS OUT'});
			$smtp->reply(421, "SMS gateway temporarily down");
			return 0;
		}
	});

	$smtp->process || next;
}
