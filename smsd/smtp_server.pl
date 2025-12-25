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

use constant USER  => 'smsd';
use constant GROUP => 'smsd';

$| = 1;  # Autoflush STDOUT

$Data::Dumper::Useqq = 0;
$Data::Dumper::Terse = 1;
$Data::Dumper::Quotekeys = 0;

# Get the script basename
my $script_name = basename($0, ".pl");

# --- Read configuration from environment ---
my $router    = $ENV{DLINK_ROUTER_IP}   or die "[SMS] Missing DLINK_ROUTER_IP env variable\n";
my $username  = $ENV{DLINK_ROUTER_USER} or die "[SMS] Missing DLINK_ROUTER_USER env variable\n";
my $password  = $ENV{DLINK_ROUTER_PASS} || "";

# --- SMTP configuration from environment ---
my $smtp_host  = $ENV{SMTP_HOST}     or die "[SMS] Missing SMTP_HOST env variable\n";
my $smtp_port  = $ENV{SMTP_PORT}     || 587;
my $smtp_user  = $ENV{SMTP_USER}     || '';
my $smtp_pass  = $ENV{SMTP_PASSWORD} || '';
my $from_email = $ENV{FROM_EMAIL}    or die "[SMS] Missing FROM_EMAIL env variable\n";
my $to_email   = $ENV{TO_EMAIL}      or die "[SMS] Missing TO_EMAIL env variable\n";

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
	my (%args) = @_;
	my $phone   = $args{phone}   or die "[SMS] Missing phone";
	my $message = $args{message} or die "[SMS] Missing message";
	my $dir     = $args{dir}     or die "[SMS] Missing directory";

	make_path($dir) unless -d $dir;

	# Sanitize phone number for filename (remove non-digits, including +)
	my $safe_phone = $phone;
	$safe_phone =~ s/\D//g;

	# Generate a random string like in send_sms()
	my $message_bytes = encode('UTF-8', $message);
	my $rand_str      = substr(md5_hex(time() . $phone . $message_bytes), 0, 10);
	my $filename      = File::Spec->catfile($dir, "${safe_phone}_$rand_str");

	eval {
		open my $fh, '>:encoding(UTF-8)', $filename or die "[SMS] " . $!;
		my $timestamp = localtime();
		print $fh "To: $phone\nSent: $timestamp\n\n$message";
		close $fh;
		print "[SMS] Saved message to $filename\n";
	};
	warn "[SMS] Failed to save SMS to $filename: $@\n" if $@;

	return $filename;
}

# --- Send SMS via router ---
sub send_sms {
	my ($phone, $message) = @_;
	die "[SMS] Missing phone or message\n" unless $phone && $message;

	$sms_busy = 1;  # Lock other SMS actions

	# 1: Ensure message is flagged as UTF-8 internally
	unless (is_utf8($message)) {
		print "[SMS] Message is NOT flagged as UTF-8 internally, decoding...\n";
		$message = decode('UTF-8', $message);
	} else {
		print "[SMS] Message is already flagged as UTF-8 internally\n";
	}

	# 2: Initialize session
	print "[SMS] Initializing session with router $router\n";
	my $init = $ua->get("http://$router/index.html");
	unless ($init->is_success) {
		warn "[SMS] HTTP GET failed: " . $init->status_line;
		$sms_busy = 0;
		die "[SMS] Failed to init session\n";
	}
	print "[SMS] Session initialized successfully\n";

	# 3: Login to router
	print "[SMS] Logging in as $username\n";
	my $md5pass = md5_hex($password);
	my $login = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => "uname=$username&passwd=$md5pass",
		Referer      => "http://$router/index.html",
		Origin       => "http://$router"
	);
	die "[SMS] Login failed\n" unless $login->is_success;
	print "[SMS] Login HTTP response code: " . $login->code . "\n";
	print "[SMS] Login Set-Cookie: " . ($login->header("Set-Cookie") || '') . "\n";

	# 4: Extract session ID from login response
	my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
	die "[SMS] qSessId not found\n" unless $qsess;
	print "[SMS] qSessId obtained: $qsess\n";

	$cookie_jar->set_cookie(0, "qSessId",     $qsess, "/", $router);
	$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

	# 5: Retrieve authorization ID (authID)
	print "[SMS] Fetching authID\n";
	my $auth_resp = $ua->get("http://$router/data.ria?token=1",
		Referer => "http://$router/controlPanel.html");
	die "[SMS] Failed to get authID\n" unless $auth_resp->is_success;
	my $authID = $auth_resp->decoded_content;
	$authID =~ s/\s+//g;
	die "[SMS] Empty authID\n" unless $authID;
	print "[SMS] authID obtained: $authID\n";

	# 6: Send SMS
	print "[SMS] Sending SMS payload\n";
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
	print "[SMS] SMS payload: " . to_json($payload, { utf8 => 0, pretty => 0 }) . "\n";

	my $json = encode_json($payload);

	my $sms = $ua->post(
		"http://$router/webpost.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => $json,
		Referer      => "http://$router/controlPanel.html",
		Origin       => "http://$router"
	);

	unless ($sms->is_success) {
		print "[SMS] SMS POST failed: " . $sms->status_line . "\n";
		print "[SMS] Response content: " . $sms->decoded_content . "\n";
		$sms_busy = 0;
		die "[SMS] SMS HTTP failed: " . $sms->code;
	}
	my $resp = $sms->decoded_content;

	# 7: Logout
	print "[SMS] Logging out session $qsess\n";
	my $logout_json = qq({"logout":"$qsess"});
	my $logout = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => $logout_json,
		Referer      => "http://$router/controlPanel.html",
		Origin       => "http://$router"
	);
	print $logout->is_success ? "[SMS] Logout successful\n" : "[SMS] Logout failed: " . $logout->status_line . "\n";

	# 8: Verify SMS sent successfully
	$sms_busy = 0;

	if ($resp =~ /"cmd_status":"Done"/ && $resp =~ /"msgSuccess":"1"/) {
		save_sms_to_file(
			phone   => $phone,
			message => $message,
			dir     => "/var/spool/sms/sent"
		);
		return 1;
	} else {
		print "[SMS] SMS gateway returned unexpected response:\n$resp\n";
		print "[SMS] JSON decode, if valid):\n";
		eval {
			my $decoded = JSON->new->utf8->pretty->canonical->decode($resp);
			print JSON->new->utf8->pretty->canonical->encode($decoded) . "\n";
		} or print "Response was not valid JSON\n";

		die "[SMS] SMS gateway error: $resp";
	}
}

# --- Read SMS periodically ---
sub read_sms {
	return if $sms_busy;

	eval {
		$sms_busy = 1;

		# 1: Initialize session
		print "[SMS] Initializing session with router $router\n";
		my $init = $ua->get("http://$router/index.html");
		die "[SMS] Failed to init session\n" unless $init->is_success;

		print "[SMS] Session initialized successfully\n";

		# 2: Login to router
		print "[SMS] Logging in as $username\n";
		my $md5pass = md5_hex($password);
		my $login = $ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content      => "uname=$username&passwd=$md5pass",
			Referer      => "http://$router/index.html",
			Origin       => "http://$router"
		);
		die "[SMS] Login failed\n" unless $login->is_success;

		my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
		die "[SMS] qSessId not found\n" unless $qsess;
		print "[SMS] qSessId obtained: $qsess\n";
		$cookie_jar->set_cookie(0, "qSessId",     $qsess, "/", $router);
		$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

		# 3: Get SMS from inbox
		print "[SMS] Fetching inbox messages\n";
		my $timestamp = int(time() * 1000);
		my $url = "http://$router/data.ria?CfgType=sms_action&cont=inbox&index=0&_=$timestamp";

		my $resp = $ua->get(
			$url,
			Referer            => "http://$router/controlPanel.html",
			'X-Requested-With' => 'XMLHttpRequest'
		);
		die "[SMS] SMS read request failed: " . $resp->status_line unless $resp->is_success;

		# 4: Parse JSON response
		my $content = $resp->decoded_content;
		my $sms_list;
		eval { $sms_list = JSON->new->utf8->decode($content) };
		if ($@) {
			warn "[SMS] Failed to decode SMS JSON: $@\n$content\n";
			$sms_busy = 0;
			return;
		}
		print "[SMS] Received " . ($sms_list->{total} || 0) . " messages\n";

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

			print "[SMS] Processing message $key\n";
			print "[SMS] \tFrom: $phone\n";
			print "[SMS] \tDate: $date\n";
			print "[SMS] \tTag:  $tag\n";
			print "[SMS] \tRead: $read\n";
			print "[SMS] \tMessage: $text\n";

			# 5a: Fetch new authID
			my $auth_resp = $ua->get(
				"http://$router/data.ria?token=1",
				Referer => "http://$router/controlPanel.html"
			);
			unless ($auth_resp->is_success) {
				warn "[SMS] Failed to get authID for tag=$tag\n";
				next;
			}
			my $authID = $auth_resp->decoded_content;
			$authID =~ s/\s+//g;
			unless ($authID) {
				warn "Empty authID for tag=$tag\n";
				next;
			}
			print "[SMS] authID obtained for tag=$tag: $authID\n";

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
				warn "DELETE FAILED for tag=$tag, status=" . $del->status_line . "\n";
				next;
			}
			print "[SMS] Deleted message tag=$tag successfully\n";

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
		print "[SMS] Logging out session $qsess\n";
		my $logout_json = qq({"logout":"$qsess"});
		my $logout = $ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content      => $logout_json,
			Referer      => "http://$router/controlPanel.html",
			Origin       => "http://$router"
		);
		print $logout->is_success ? "[SMS] Logout successful\n" : "[SMS] Logout failed: " . $logout->status_line . "\n";

		$sms_busy = 0;
		return $sms_list;
	};
	if ($@) {
		warn "[SMS] Error in read_sms: $@\n";
		$sms_busy = 0;
	}
}

# --- Forward SMS via email ---
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
			) or do { warn "[SMTP] SMTP connect failed\n"; next; };

			# Start TLS if using port 587
			eval { $smtp->starttls() } if $smtp_port == 587;

			# Authenticate if credentials provided
			if ($smtp_user && $smtp_pass) {
				unless ($smtp->auth($smtp_user, $smtp_pass)) {
					warn "[SMTP] SMTP auth failed\n";
					$smtp->quit;
					next;
				}
			} else {
				# Warn if credentials are missing and you expected them
				warn "[SMTP] SMTP credentials not provided, skipping auth\n";
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

			print "[SMTP] Forwarded SMS from $phone to: $recipient\n";
		}

		# Mark as sent to avoid duplicate forwarding
		$sent_sms{$text} = 1;
	};
	warn "[SMS] Failed to send email for SMS from $phone: $@\n" if $@;
}

# --- Background thread to read SMS ---
threads->create(sub {
	while (1) {
		read_sms();
		sleep(10);
	}
})->detach();

# --- SMTP server ---
my $socket = IO::Socket::INET->new(
	LocalPort => 25,
	Listen    => 5,
	Proto     => 'tcp',
	Reuse     => 1,
) or die "[SMTP] Unable to bind port 25: $!";

print "[SMTP] SMS Gateway running on port 25...\n";

# Main loop: accept SMTP clients
while (my $client = $socket->accept()) {
	print "[SMTP] Accepted connection from ", $client->peerhost, ":", $client->peerport, "\n";

	my $smtp = Net::Server::Mail::SMTP->new(socket => $client);

	$smtp->set_callback(RCPT => sub {
		my ($session, $rcpt) = @_;
		$rcpt =~ s/\D//g;
		$session->{_sms_to} = $rcpt;
		print "[SMTP] RCPT TO: $rcpt\n";
		return 1;
	});

	$smtp->set_callback(DATA => sub {
		my ($session, $data) = @_;

		my $email = Email::Simple->new($data);
		my $subject = $email->header('Subject') || '';
		my $body    = $email->body || '';
		my $message = ($subject && $body) ? "$subject $body" : ($subject . $body);
		my $dest    = $session->{_sms_to};

		print "[SMTP] Sending SMS to $dest ...\n";
		my $ok = eval { send_sms($dest, $message) };

		if ($ok) {
			print "[SMTP] ✔ SMS to $dest sent successfully\n";
			return 1;
		} else {
			print "[SMTP] ❌ SMS to $dest failed: $@\n";
			$smtp->reply(421, "SMS gateway temporarily down");
			return 0;
		}
	});

	$smtp->process || next;
}
