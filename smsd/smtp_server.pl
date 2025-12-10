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

use constant USER  => 'smsd';
use constant GROUP => 'smsd';

$| = 1;  # Autoflush STDOUT

$Data::Dumper::Useqq = 0;
$Data::Dumper::Terse = 1;
$Data::Dumper::Quotekeys = 0;

# --- Helper to prepend timestamp ---
sub ts {
	my $t = localtime();
	return "[$t] ";
}

# --- Read configuration from environment ---
my $router    = $ENV{DLINK_ROUTER_IP}   or die "Missing DLINK_ROUTER_IP env variable\n";
my $username  = $ENV{DLINK_ROUTER_USER} or die "Missing DLINK_ROUTER_USER env variable\n";
my $password  = $ENV{DLINK_ROUTER_PASS} || "";

# --- SMTP configuration from environment ---
my $smtp_host  = $ENV{SMTP_HOST}     or die "Missing SMTP_HOST env variable\n";
my $smtp_port  = $ENV{SMTP_PORT}     || 587;
my $smtp_user  = $ENV{SMTP_USER}     || '';
my $smtp_pass  = $ENV{SMTP_PASSWORD} || '';
my $from_email = $ENV{FROM_EMAIL}    or die "Missing FROM_EMAIL env variable\n";
my $to_email   = $ENV{TO_EMAIL}      or die "Missing TO_EMAIL env variable\n";

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

# --- Function to save a message to disk ---
sub save_sms_to_file {
	my (%args) = @_;
	my $phone   = $args{phone}   or die "Missing phone";
	my $message = $args{message} or die "Missing message";
	my $dir     = $args{dir}     or die "Missing directory";

	make_path($dir) unless -d $dir;

	# Generate a random string like in send_sms()
	my $message_bytes = encode('UTF-8', $message);
	my $rand_str      = substr(md5_hex(time() . $phone . $message_bytes), 0, 10);
	my $filename      = File::Spec->catfile($dir, "${phone}_$rand_str");

	eval {
		open my $fh, '>:encoding(UTF-8)', $filename or die $!;
		my $timestamp = localtime();
		print $fh "To: $phone\nSent: $timestamp\n\n$message";
		close $fh;
		print ts(), "Saved message to $filename\n";
	};
	warn ts() . "Failed to save SMS to $filename: $@\n" if $@;

	return $filename;
}

# --- Function to send SMS via the router ---
sub send_sms {
	my ($phone, $message) = @_;
	die "Missing phone or message\n" unless $phone && $message;

	$sms_busy = 1;  # Lock other SMS actions

	# 1: Ensure message is flagged as UTF-8 internally
	unless (is_utf8($message)) {
		print ts(), "Message is NOT flagged as UTF-8 internally, decoding...\n";
		$message = decode('UTF-8', $message);
	} else {
		print ts(), "Message is already flagged as UTF-8 internally\n";
	}

	# 2: Initialize session
	print ts(), "Initializing session with router $router\n";
	my $init = $ua->get("http://$router/index.html");
	unless ($init->is_success) {
		warn ts() . "HTTP GET failed: " . $init->status_line;
		$sms_busy = 0;
		die ts() . "Failed to init session\n";
	}
	print ts(), "Session initialized successfully\n";

	# 3: Login to router
	print ts(), "Logging in as $username\n";
	my $md5pass = md5_hex($password);
	my $login = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => "uname=$username&passwd=$md5pass",
		Referer      => "http://$router/index.html",
		Origin       => "http://$router"
	);
	die ts() . "Login failed\n" unless $login->is_success;
	print ts(), "Login HTTP response code: " . $login->code . "\n";
	print ts(), "Login Set-Cookie: " . ($login->header("Set-Cookie") || '') . "\n";

	# 4: Extract session ID from login response
	my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
	die ts() . "qSessId not found\n" unless $qsess;
	print ts(), "qSessId obtained: $qsess\n";
	$cookie_jar->set_cookie(0, "qSessId",     $qsess, "/", $router);
	$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

	# 5: Retrieve authorization ID (authID)
	print ts(), "Fetching authID\n";
	my $auth_resp = $ua->get("http://$router/data.ria?token=1",
		Referer => "http://$router/controlPanel.html");
	die ts() . "Failed to get authID\n" unless $auth_resp->is_success;
	my $authID = $auth_resp->decoded_content;
	$authID =~ s/\s+//g;
	die ts() . "Empty authID\n" unless $authID;
	print ts(), "authID obtained: $authID\n";

	# 6: Send SMS
	print ts(), "Sending SMS payload\n";
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
	print ts(), "SMS payload: " . to_json($payload, { utf8 => 0, pretty => 0 }) . "\n";
	my $json = encode_json($payload);

	my $sms = $ua->post(
		"http://$router/webpost.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => $json,
		Referer      => "http://$router/controlPanel.html",
		Origin       => "http://$router"
	);

	unless ($sms->is_success) {
		print ts() . "SMS POST failed: " . $sms->status_line . "\n";
		print ts() . "Response content: " . $sms->decoded_content . "\n";
		$sms_busy = 0;
		die ts() . "SMS HTTP failed: " . $sms->code;
	}
	my $resp = $sms->decoded_content;

	# 7: Logout
	print ts(), "Logging out session $qsess\n";
	my $logout_json = qq({"logout":"$qsess"});
	my $logout = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => $logout_json,
		Referer      => "http://$router/controlPanel.html",
		Origin       => "http://$router"
	);
	print ts(), $logout->is_success ? "Logout successful\n" : "Logout failed: " . $logout->status_line . "\n";

	# 8: Verify SMS sent successfully
	if ($resp =~ /"cmd_status":"Done"/ && $resp =~ /"msgSuccess":"1"/) {
		save_sms_to_file(
			phone   => $phone,
			message => $message,
			dir     => "/var/spool/sms/sent"
		);

		$sms_busy = 0;
		return 1;
	} else {
		print ts(), "SMS gateway returned unexpected response:\n$resp\n";
		print ts(), "JSON decode, if valid):\n";
		eval {
			my $decoded = JSON->new->utf8->pretty->canonical->decode($resp);
			print ts() . JSON->new->utf8->pretty->canonical->encode($decoded) . "\n";
		} or print ts() . "Response was not valid JSON\n";

		$sms_busy = 0;
		die ts() . "SMS gateway error: $resp";
	}
}

sub read_sms {
	return if $sms_busy;

	eval {
		$sms_busy = 1;

		# 1: Initialize session
		print ts(), "Initializing session with router $router\n";
		my $init = $ua->get("http://$router/index.html");
		die ts() . "Failed to init session\n" unless $init->is_success;
		print ts(), "Session initialized successfully\n";

		# 2: Login to router
		print ts(), "Logging in as $username\n";
		my $md5pass = md5_hex($password);
		my $login = $ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content      => "uname=$username&passwd=$md5pass",
			Referer      => "http://$router/index.html",
			Origin       => "http://$router"
		);
		die ts() . "Login failed\n" unless $login->is_success;

		my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
		die ts() . "qSessId not found\n" unless $qsess;
		print ts(), "qSessId obtained: $qsess\n";
		$cookie_jar->set_cookie(0, "qSessId",     $qsess, "/", $router);
		$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

		# 3: Get SMS from inbox
		print ts(), "Fetching inbox messages\n";
		my $timestamp = int(time() * 1000);
		my $url = "http://$router/data.ria?CfgType=sms_action&cont=inbox&index=0&_=$timestamp";

		my $resp = $ua->get(
			$url,
			Referer            => "http://$router/controlPanel.html",
			'X-Requested-With' => 'XMLHttpRequest'
		);
		die ts() . "SMS read request failed: " . $resp->status_line unless $resp->is_success;

		# 4: Parse JSON response
		my $content = $resp->decoded_content;
		my $sms_list;
		eval { $sms_list = JSON->new->utf8->decode($content) };
		if ($@) {
			warn ts() . "Failed to decode SMS JSON: $@\n$content\n";
			$sms_busy = 0;
			return;
		}
		print ts(), "Received " . ($sms_list->{total} || 0) . " messages\n";

		my $incoming_dir = "/var/spool/sms/incoming";
		make_path($incoming_dir) unless -d $incoming_dir;

		# 5: Process messages
		for my $key (grep { /^M\d+$/ } keys %$sms_list) {
			my $msg   = $sms_list->{$key};
			my $phone = $msg->{phone} || '';
			my $date  = $msg->{date}  || '';
			my $tag   = $msg->{tag}   || '';
			my $text  = $msg->{msg}   || '';
			my $read  = $msg->{read}  || 0;

			print ts(), "Processing message $key\n";
			print ts(), "\tFrom: $phone\n";
			print ts(), "\tDate: $date\n";
			print ts(), "\tTag:  $tag\n";
			print ts(), "\tRead: $read\n";
			print ts(), "\tMessage: $text\n";

			# 5a: Fetch new authID
			my $auth_resp = $ua->get(
				"http://$router/data.ria?token=1",
				Referer => "http://$router/controlPanel.html"
			);
			unless ($auth_resp->is_success) {
				warn ts() . "Failed to get authID for tag=$tag\n";
				next;
			}
			my $authID = $auth_resp->decoded_content;
			$authID =~ s/\s+//g;
			unless ($authID) {
				warn ts() . "Empty authID for tag=$tag\n";
				next;
			}
			print ts(), "authID obtained for tag=$tag: $authID\n";

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
				warn ts() . "DELETE FAILED for tag=$tag, status=" . $del->status_line . "\n";
				next;
			}
			print ts(), "Deleted message tag=$tag successfully\n";

			# 5d: Save to spool
			save_sms_to_file(
				phone   => $phone,
				message => $text,
				dir     => $incoming_dir
			);

			# 5e: Forward SMS via email
			forward_sms_email($phone, $text);
		}

		# 6: Logout
		print ts(), "Logging out session $qsess\n";
		my $logout_json = qq({"logout":"$qsess"});
		my $logout = $ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content      => $logout_json,
			Referer      => "http://$router/controlPanel.html",
			Origin       => "http://$router"
		);
		print ts(), $logout->is_success ? "Logout successful\n" : "Logout failed: " . $logout->status_line . "\n";

		$sms_busy = 0;
		return $sms_list;
	};
	if ($@) {
		warn ts() . "Error in read_sms: $@\n";
		$sms_busy = 0;
	}
}

# --- Function to forward sms via email ---
sub forward_sms_email {
	my ($phone, $text) = @_;
	return if $sent_sms{$text};

	eval {
		# Normalize line endings to CRLF for SMTP compliance
		$text =~ s/\r?\n/\r\n/g;

		# Encode UTF-8 flagged string to bytes
		my $utf8_text = encode('UTF-8', $text);

		# Create proper Email::MIME object
		my $email = Email::MIME->create(
			header_str => [
				From    => $smtp_user || $from_email,
				To      => join(", ", @to_list),
				Subject => "SMS from $phone",
			],
			attributes => { encoding => 'quoted-printable', charset => 'UTF-8' },
			body       => $utf8_text,
		);

		# Loop over each recipient and send individually
		foreach my $recipient (@to_list) {

			# Connect to SMTP server
			my $smtp = Net::SMTP->new(
				$smtp_host,
				Port            => $smtp_port,
				Timeout         => 20,
				Debug           => 0,
				SSL_verify_mode => 0,
			) or do { warn ts() . "SMTP connect failed\n"; next; };

			# Start TLS if using port 587
			eval { $smtp->starttls() } if $smtp_port == 587;

			# Authenticate if credentials provided
			if ($smtp_user && $smtp_pass) {
				unless ($smtp->auth($smtp_user, $smtp_pass)) {
					warn ts() . "SMTP auth failed\n";
					$smtp->quit;
					next;
				}
			} else {
				# Warn if credentials are missing and you expected them
				warn ts() . "SMTP credentials not provided, skipping auth\n";
			}

			# Set sender and recipient
			$smtp->mail($smtp_user || $from_email);
			$smtp->to($recipient);

			# Send the full Email::MIME message
			$smtp->data();
			$smtp->datasend($email->as_string);
			$smtp->dataend();

			# Close SMTP session
			$smtp->quit();

			print ts(), "Forwarded SMS from $phone to: $recipient\n";
		}

		# Save forwarded SMS with same filename format
		save_sms_to_file(
			phone   => $phone,
			message => $text,
			dir     => "/var/spool/sms/sent"
		);

		$sent_sms{$text} = 1;
	};
	warn ts() . "Failed to send email for SMS from $phone: $@\n" if $@;
}

# --- Background thread to read SMS periodically ---
threads->create(sub {
	while (1) {
		read_sms();
		sleep(10);
	}
})->detach();

# --- SMTP server to accept incoming emails and forward as SMS ---
my $socket = IO::Socket::INET->new(
	LocalPort => 25,
	Listen    => 5,
	Proto     => 'tcp',
	Reuse     => 1,
) or die "Unable to bind SMTP server port 25: $!";

print ts(), "SMTP SMS Gateway running on port 25...\n";

# Main loop: accept SMTP clients
while (my $client = $socket->accept()) {
	my $smtp = Net::Server::Mail::SMTP->new(socket => $client);

	$smtp->set_callback(RCPT => sub {
		my ($session, $rcpt) = @_;
		$rcpt =~ s/\D//g;
		$session->{_sms_to} = $rcpt;
		return 1;
	});

	$smtp->set_callback(DATA => sub {
		my ($session, $data) = @_;

		my $email = Email::Simple->new($data);
		my $subject = $email->header('Subject') || '';
		my $body    = $email->body || '';
		my $message = ($subject && $body) ? "$subject $body" : ($subject . $body);
		my $dest    = $session->{_sms_to};

		print ts(), "Sending SMS to $dest ...\n";
		my $ok = eval { send_sms($dest, $message) };

		if ($ok) {
			print ts(), "✔ SMS to $dest sent successfully\n";
			return 1;
		} else {
			warn ts() . "❌ SMS to $dest failed: $@\n";
			$smtp->reply(421, "SMS gateway temporarily down");
			return 0;
		}
	});

	$smtp->process || next;
}
