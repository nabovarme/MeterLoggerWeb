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
use Digest::MD5 qw(md5_hex);
use JSON qw(encode_json to_json);
use File::Path qw(make_path);
use File::Spec;
use Time::HiRes qw(sleep);
use threads;

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
my $router    = $ENV{DLINK_ROUTER_IP}   or log_die("Missing DLINK_ROUTER_IP env variable", {-no_script_name => 1, -custom_tag => 'SMS' });
my $username  = $ENV{DLINK_ROUTER_USER} or log_die("Missing DLINK_ROUTER_USER env variable", {-no_script_name => 1, -custom_tag => 'SMS' });
my $password  = $ENV{DLINK_ROUTER_PASS} || "";

# --- SMTP configuration from environment ---
my $smtp_host  = $ENV{SMTP_HOST}     or log_die("Missing SMTP_HOST env variable", {-no_script_name => 1, -custom_tag => 'SMTP' });
my $smtp_port  = $ENV{SMTP_PORT}     || 587;
my $smtp_user  = $ENV{SMTP_USER}     || '';
my $smtp_pass  = $ENV{SMTP_PASSWORD} || '';
my $from_email = $ENV{FROM_EMAIL}    or log_die("Missing FROM_EMAIL env variable", {-no_script_name => 1, -custom_tag => 'SMTP' });
my $to_email   = $ENV{TO_EMAIL}      or log_die("Missing TO_EMAIL env variable", {-no_script_name => 1, -custom_tag => 'SMTP' });

my @to_list = split /[\s,]+/, $to_email;

# --- Initialize HTTP client for SMS with cookies and headers ---
my $cookie_jar = HTTP::Cookies->new;
my $ua = LWP::UserAgent->new(
	agent      => "Mozilla/5.0",
	cookie_jar => $cookie_jar,
	timeout    => 30,
);
$ua->default_header("Accept"            => "application/json, text/javascript, */*; q=0.01");
$ua->default_header("Accept-Language"   => "en-GB,en;q=0.9");
$ua->default_header("Connection"        => "keep-alive");
$ua->default_header("X-Requested-With"  => "XMLHttpRequest");

# --- Global flag to prevent concurrent send_sms/read_sms ---
my $sms_busy = 0;
my %sent_sms;

# --- Save SMS to file ---
sub save_sms_to_file {
	my ($phone, $message, $dir) = @_;	
	$phone   or log_die("Missing phone", {-no_script_name => 1, -custom_tag => 'SMS' });
	$message or log_die("Missing message", {-no_script_name => 1, -custom_tag => 'SMS' });
	$dir     or log_die("Missing directory", {-no_script_name => 1, -custom_tag => 'SMS' });

	make_path($dir) unless -d $dir;

	# Sanitize phone number for filename (remove non-digits, including +)
	my $safe_phone = $phone;
	$safe_phone =~ s/\D//g;

	# Generate a random string like in send_sms()
	my $message_bytes = encode('UTF-8', $message);
	my $rand_str      = substr(md5_hex(time() . $phone . $message_bytes), 0, 10);
	my $filename      = File::Spec->catfile($dir, "${safe_phone}_$rand_str");

	eval {
		open my $fh, '>:encoding(UTF-8)', $filename or log_die("Failed to open file: $!", {-no_script_name => 1, -custom_tag => 'SMS' });
		my $timestamp = localtime();
		print $fh "To: $phone\nSent: $timestamp\n\n$message";
		close $fh;
		log_info("Saved message to $filename", {-no_script_name => 1, -custom_tag => 'SMS' });
	};
	log_warn("Failed to save SMS to $filename: $@", {-no_script_name => 1, -custom_tag => 'SMS' }) if $@;

	return $filename;
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

# --- Send SMS via router ---
sub send_sms {
	my ($phone, $message) = @_;
	log_die("Missing phone or message", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $phone && $message;

	if ($dry_run) {
		log_info("DRY RUN: send_sms called for $phone with message: $message", {-no_script_name => 1, -custom_tag => 'SMS'});
		save_sms_to_file(
			$phone,
			$message,
			"/var/spool/sms/sent"
		);
		
		# Log to DB
		log_sms_to_db(
			$dbh,
			'sent',
			$phone,
			$message
		);
		return 1;
	}

	$sms_busy = 1;  # Lock other SMS actions

	# 1: Ensure message is flagged as UTF-8 internally
	unless (is_utf8($message)) {
		log_info("Message is NOT flagged as UTF-8 internally, decoding...", {-no_script_name => 1, -custom_tag => 'SMS' });
		$message = decode('UTF-8', $message);
	} else {
		log_info("Message is already flagged as UTF-8 internally", {-no_script_name => 1, -custom_tag => 'SMS' });
	}

	# 2: Initialize session
	log_info("Initializing session with router $router", {-no_script_name => 1, -custom_tag => 'SMS' });
	my $init = $ua->get("http://$router/index.html");
	unless ($init->is_success) {
		log_warn("HTTP GET failed: " . $init->status_line, {-no_script_name => 1, -custom_tag => 'SMS' });
		$sms_busy = 0;
		log_die("Failed to init session", {-no_script_name => 1, -custom_tag => 'SMS' });
	}
	log_info("Session initialized successfully", {-no_script_name => 1, -custom_tag => 'SMS' });

	# 3: Login to router
	log_info("Logging in as $username", {-no_script_name => 1, -custom_tag => 'SMS' });
	my $md5pass = md5_hex($password);
	my $login = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => "uname=$username&passwd=$md5pass",
		Referer      => "http://$router/index.html",
		Origin       => "http://$router"
	);
	log_die("Login failed", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $login->is_success;

	log_info("Login HTTP response code: " . $login->code, {-no_script_name => 1, -custom_tag => 'SMS' });
	log_info("Login Set-Cookie: " . ($login->header("Set-Cookie") || ''), {-no_script_name => 1, -custom_tag => 'SMS' });

	# 4: Extract session ID from login response
	my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
	log_die("qSessId not found", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $qsess;

	log_info("qSessId obtained: $qsess", {-no_script_name => 1, -custom_tag => 'SMS' });

	$cookie_jar->set_cookie(0, "qSessId",     $qsess, "/", $router);
	$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

	# 5: Retrieve authorization ID (authID)
	log_info("Fetching authID", {-no_script_name => 1, -custom_tag => 'SMS' });
	my $auth_resp = $ua->get("http://$router/data.ria?token=1", Referer => "http://$router/controlPanel.html");
	log_die("Failed to get authID", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $auth_resp->is_success;

	my $authID = $auth_resp->decoded_content;
	$authID =~ s/\s+//g;
	log_die("Empty authID", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $authID;

	log_info("authID obtained: $authID", {-no_script_name => 1, -custom_tag => 'SMS' });

	# 6: Send SMS
	log_info("Sending SMS payload", {-no_script_name => 1, -custom_tag => 'SMS' });
	my $csrf = sprintf("%06d", int(rand(999_999)));
	$ua->default_header("X-Csrf-Token" => $csrf);

	my $payload_phone = $phone =~ /^\+/ ? $phone : '+' . $phone;
	my $payload = {
		CfgType    => "sms_action",
		type       => "sms_send",
		msg        => $message,
		phone_list => $payload_phone,
		authID     => $authID
	};
	log_debug("SMS payload: " . to_json($payload, { utf8 => 0, pretty => 0 }), {-no_script_name => 1, -custom_tag => 'SMS' });

	my $json = encode_json($payload);

	my $sms = $ua->post(
		"http://$router/webpost.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => $json,
		Referer      => "http://$router/controlPanel.html",
		Origin       => "http://$router"
	);

	unless ($sms->is_success) {
		log_warn("SMS POST failed: " . $sms->status_line, {-no_script_name => 1, -custom_tag => 'SMS' });
		log_warn("Response content: " . $sms->decoded_content, {-no_script_name => 1, -custom_tag => 'SMS' });
		$sms_busy = 0;
		log_die("SMS HTTP failed: " . $sms->code, {-no_script_name => 1, -custom_tag => 'SMS' });
	}

	my $resp = $sms->decoded_content;

	# 7: Logout
	log_info("Logging out session $qsess", {-no_script_name => 1, -custom_tag => 'SMS' });
	my $logout_json = qq({"logout":"$qsess"});
	my $logout = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => $logout_json,
		Referer      => "http://$router/controlPanel.html",
		Origin       => "http://$router"
	);
	log_info($logout->is_success ? "Logout successful" : "Logout failed: " . $logout->status_line, {-no_script_name => 1, -custom_tag => 'SMS' });

	# 8: Verify SMS sent successfully
	$sms_busy = 0;

	if ($resp =~ /"cmd_status":"Done"/ && $resp =~ /"msgSuccess":"1"/) {
		save_sms_to_file(
			$phone,
			$message,
			"/var/spool/sms/sent"
		);
		
		# Log to DB
		log_sms_to_db(
			$dbh,
			'sent',
			$phone,
			$message
		);
		return 1;
	} else {
		log_warn("SMS gateway returned unexpected response:\n$resp", {-no_script_name => 1, -custom_tag => 'SMS' });
		eval {
			my $decoded = JSON->new->utf8->pretty->canonical->decode($resp);
			log_debug(JSON->new->utf8->pretty->canonical->encode($decoded), {-no_script_name => 1, -custom_tag => 'SMS' });
		} or log_warn("Response was not valid JSON", {-no_script_name => 1, -custom_tag => 'SMS' });

		log_die("SMS gateway error: $resp", {-no_script_name => 1, -custom_tag => 'SMS' });
	}
}

# --- Read SMS periodically ---
sub read_sms {
	my ($dbh_thread) = @_;
	return if $sms_busy;

	eval {
		$sms_busy = 1;

		# 1: Initialize session
		log_info("Initializing session with router $router", {-no_script_name => 1, -custom_tag => 'SMS' });
		my $init = $ua->get("http://$router/index.html");
		log_die("Failed to init session", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $init->is_success;
		log_info("Session initialized successfully", {-no_script_name => 1, -custom_tag => 'SMS' });

		# 2: Login to router
		log_info("Logging in as $username", {-no_script_name => 1, -custom_tag => 'SMS' });
		my $md5pass = md5_hex($password);
		my $login = $ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content      => "uname=$username&passwd=$md5pass",
			Referer      => "http://$router/index.html",
			Origin       => "http://$router"
		);
		log_die("Login failed", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $login->is_success;

		my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
		log_die("qSessId not found", {-no_script_name => 1, -custom_tag => 'SMS' }) unless $qsess;
		log_info("qSessId obtained: $qsess", {-no_script_name => 1, -custom_tag => 'SMS' });
		$cookie_jar->set_cookie(0, "qSessId",     $qsess, "/", $router);
		$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

		# 3: Get SMS from inbox
		log_info("Fetching inbox messages", {-no_script_name => 1, -custom_tag => 'SMS' });
		my $timestamp = int(time() * 1000);
		my $url = "http://$router/data.ria?CfgType=sms_action&cont=inbox&index=0&_=$timestamp";

		my $resp = $ua->get(
			$url,
			Referer            => "http://$router/controlPanel.html",
			'X-Requested-With' => 'XMLHttpRequest'
		);
		log_die("SMS read request failed: " . $resp->status_line, {-no_script_name => 1, -custom_tag => 'SMS' }) unless $resp->is_success;

		# 4: Parse JSON response
		my $content = $resp->decoded_content;
		my $sms_list;
		eval { $sms_list = JSON->new->utf8->decode($content) };
		if ($@) {
			log_warn("Failed to decode SMS JSON: $@\n$content", {-no_script_name => 1, -custom_tag => 'SMS' });
			$sms_busy = 0;
			return;
		}
		log_info("Received " . ($sms_list->{total} || 0) . " messages", {-no_script_name => 1, -custom_tag => 'SMS' });

		my $incoming_dir = "/var/spool/sms/incoming";
		make_path($incoming_dir) unless -d $incoming_dir;

		# 5: Process messages
		for my $key (grep { /^M\d+$/ } keys %$sms_list) {
			my $msg     = $sms_list->{$key};
			my $phone   = $msg->{phone} || '';
			my $date    = $msg->{date}  || '';
			my $tag     = $msg->{tag}   || '';
			my $message = $msg->{msg}   || '';
			my $read    = $msg->{read}  || 0;

			log_info("Processing message $key", {-no_script_name => 1, -custom_tag => 'SMS' });
			log_info("\tFrom: $phone", {-no_script_name => 1, -custom_tag => 'SMS' });
			log_info("\tDate: $date", {-no_script_name => 1, -custom_tag => 'SMS' });
			log_info("\tTag:  $tag", {-no_script_name => 1, -custom_tag => 'SMS' });
			log_info("\tRead: $read", {-no_script_name => 1, -custom_tag => 'SMS' });
			log_info("\tMessage: $message", {-no_script_name => 1, -custom_tag => 'SMS' });

			# 5a: Fetch new authID
			my $auth_resp = $ua->get(
				"http://$router/data.ria?token=1",
				Referer => "http://$router/controlPanel.html"
			);
			unless ($auth_resp->is_success) {
				log_warn("Failed to get authID for tag=$tag", {-no_script_name => 1, -custom_tag => 'SMS' });
				next;
			}
			my $authID = $auth_resp->decoded_content;
			$authID =~ s/\s+//g;
			unless ($authID) {
				log_warn("Empty authID for tag=$tag", {-no_script_name => 1, -custom_tag => 'SMS' });
				next;
			}
			log_info("authID obtained for tag=$tag: $authID", {-no_script_name => 1, -custom_tag => 'SMS' });

			# 5b: Generate CSRF token
			my $csrf = sprintf("%06d", int(rand(999_999)));
			$ua->default_header("X-Csrf-Token" => $csrf);

			# 5c: Delete message
			my $del_payload = qq({"CfgType":"sms_action","type":"inbox","cmd":"del","tag":"$tag","authID":"$authID"});
			my $del = $ua->post(
				"http://$router/webpost.cgi",
				Content_Type      => "application/x-www-form-urlencoded; charset=UTF-8",
				Content           => $del_payload,
				Referer           => "http://$router/controlPanel.html",
				Origin            => "http://$router",
				'X-Requested-With'=> 'XMLHttpRequest'
			);
			unless ($del->is_success) {
				log_warn("DELETE FAILED for tag=$tag, status=" . $del->status_line, {-no_script_name => 1, -custom_tag => 'SMS' });
				next;
			}
			log_info("Deleted message tag=$tag successfully", {-no_script_name => 1, -custom_tag => 'SMS' });

			# 5d: Save to spool
			save_sms_to_file(
				$phone,
				$message,
				$incoming_dir
			);
			
			# Log to DB using thread-safe handle
			log_sms_to_db(
				$dbh_thread,
				'received',
				$phone,
				$message
			);

			# 5e: Forward SMS via email
			forward_sms_email($phone, $message);
		}

		# 6: Logout
		log_info("Logging out session $qsess", {-no_script_name => 1, -custom_tag => 'SMS' });
		my $logout_json = qq({"logout":"$qsess"});
		my $logout = $ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content      => $logout_json,
			Referer      => "http://$router/controlPanel.html",
			Origin       => "http://$router"
		);
		log_info($logout->is_success ? "Logout successful" : "Logout failed: " . $logout->status_line, {-no_script_name => 1, -custom_tag => 'SMS' });

		$sms_busy = 0;
		return $sms_list;
	};
	if ($@) {
		log_warn("Error in read_sms: $@", {-no_script_name => 1, -custom_tag => 'SMS' });
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
			$smtp->mail($smtp_user || $from_email)
				or log_die("SMTP MAIL FROM failed", {-no_script_name => 1, -custom_tag => 'SMTP' });
			$smtp->to($recipient)
				or log_die("SMTP RCPT TO failed for $recipient", {-no_script_name => 1, -custom_tag => 'SMTP' });

			$smtp->data()
				or log_die("SMTP DATA failed", {-no_script_name => 1, -custom_tag => 'SMTP' });
			$smtp->datasend($email->as_string)
				or log_die("SMTP DATASEND failed", {-no_script_name => 1, -custom_tag => 'SMTP' });
			$smtp->dataend()
				or log_die("SMTP DATAEND failed", {-no_script_name => 1, -custom_tag => 'SMTP' });

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
	log_info("DRY RUN: SMS reading thread skipped", {-no_script_name => 1, -custom_tag => 'SMS'});
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
			log_warn(" Message is NOT flagged as UTF-8 internally, decoding...", {-no_script_name => 1, -custom_tag => 'SMS'});
			$message = decode('UTF-8', $message);
		} else {
			log_warn(" Message is already flagged as UTF-8 internally", {-no_script_name => 1, -custom_tag => 'SMS'});
		}
		
		my $dest = $session->{_sms_to};

		log_info("Sending SMS to $dest ...", {-no_script_name => 1, -custom_tag => 'SMS' });
		my $ok = eval { send_sms($dest, $message) };

		if ($ok) {
			log_info("✔ SMS to $dest sent successfully", {-no_script_name => 1, -custom_tag => 'SMS' });
			return 1;
		} else {
			log_warn("❌ SMS to $dest failed: $@", {-no_script_name => 1, -custom_tag => 'SMS'});
			$smtp->reply(421, "SMS gateway temporarily down");
			return 0;
		}
	});

	$smtp->process || next;
}
