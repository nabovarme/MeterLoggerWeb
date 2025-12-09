#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);

use Carp;
use Encode qw(encode decode is_utf8);
use Email::Simple;
use Data::Dumper;

use Net::Server::Mail::SMTP;
use IO::Socket::INET;

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

# --- Read configuration from environment ---
my $router   = $ENV{DLINK_ROUTER_IP}   or die "Missing DLINK_ROUTER_IP env variable\n";
my $username = $ENV{DLINK_ROUTER_USER} or die "Missing DLINK_ROUTER_USER env variable\n";
my $password = $ENV{DLINK_ROUTER_PASS} // "";

# --- Initialize HTTP client for SMS with cookies and headers ---
my $cookie_jar = HTTP::Cookies->new;
my $ua = LWP::UserAgent->new(
	agent	   => "Mozilla/5.0",
	cookie_jar => $cookie_jar,
	timeout	   => 30,
);
$ua->default_header("Accept"		   => "application/json, text/javascript, */*; q=0.01");
$ua->default_header("Accept-Language" => "en-GB,en;q=0.9");
$ua->default_header("Connection"	   => "keep-alive");
$ua->default_header("X-Requested-With" => "XMLHttpRequest");

# --- Global flag to prevent concurrent send_sms/read_sms ---
my $sms_busy = 0;

# --- Function to send SMS via the router ---
sub send_sms {
	my ($phone, $message) = @_;
	die "Missing phone or message\n" unless $phone && $message;

	$sms_busy = 1;  # Lock other SMS actions

	# --- STEP 0: Ensure message is flagged as UTF-8 internally ---
	unless (is_utf8($message)) {
		print "Message is NOT flagged as UTF-8 internally, decoding...\n";
		$message = decode('UTF-8', $message);
	} else {
		print "Message is already flagged as UTF-8 internally\n";
	}

	# --- STEP 1: Initialize session ---
	print "Initializing session with router $router\n";
	my $init = $ua->get("http://$router/index.html");
	unless ($init->is_success) {
		warn "HTTP GET failed: " . $init->status_line;
		$sms_busy = 0;
		die "Failed to init session\n";
	}
	print "Session initialized successfully\n";

	# --- STEP 2: Login to router ---
	print "Logging in as $username\n";
	my $md5pass = md5_hex($password);
	my $login = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content	   => "uname=$username&passwd=$md5pass",
		Referer	   => "http://$router/index.html",
		Origin	   => "http://$router"
	);
	die "Login failed\n" unless $login->is_success;
	print "Login HTTP response code: " . $login->code . "\n";
	print "Login Set-Cookie: " . ($login->header("Set-Cookie") // '') . "\n";

	# --- Extract session ID from login response ---
	my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
	die "qSessId not found\n" unless $qsess;
	print "qSessId obtained: $qsess\n";
	$cookie_jar->set_cookie(0, "qSessId",	 $qsess, "/", $router);
	$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

	# --- STEP 3: Retrieve authorization ID (authID) ---
	print "Fetching authID\n";
	my $auth_resp = $ua->get("http://$router/data.ria?token=1",
		Referer => "http://$router/controlPanel.html");
	die "Failed to get authID\n" unless $auth_resp->is_success;
	my $authID = $auth_resp->decoded_content;
	$authID =~ s/\s+//g;
	die "Empty authID\n" unless $authID;
	print "authID obtained: $authID\n";

	# --- STEP 4: Send SMS ---
	print "Sending SMS payload\n";
	my $csrf = sprintf("%06d", int(rand(999_999)));
	$ua->default_header("X-Csrf-Token" => $csrf);

	# Prepare phone number for sending (prepend '+' only for payload)
	my $payload_phone = $phone =~ /^\+/ ? $phone : '+' . $phone;
	my $payload = {
		CfgType	  => "sms_action",
		type	  => "sms_send",
		msg		  => $message,
		phone_list => $payload_phone,
		authID	  => $authID
	};
	print "SMS payload: " . to_json($payload, { utf8 => 0, pretty => 0 }) . "\n";
	my $json = encode_json($payload);

	my $sms = $ua->post(
		"http://$router/webpost.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content	  => $json,
		Referer	  => "http://$router/controlPanel.html",
		Origin	   => "http://$router"
	);

	# --- Handle HTTP errors for SMS POST ---
	unless ($sms->is_success) {
		print "SMS POST failed: " . $sms->status_line . "\n";
		print "Response content: " . $sms->decoded_content . "\n";
		$sms_busy = 0;
		die "SMS HTTP failed: " . $sms->code;
	}
	my $resp = $sms->decoded_content;

	# --- STEP 5: Logout from router session ---
	print "Logging out session $qsess\n";
	my $logout_json = qq({"logout":"$qsess"});
	my $logout = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content	   => $logout_json,
		Referer	   => "http://$router/controlPanel.html",
		Origin	   => "http://$router"
	);
	print $logout->is_success ? "Logout successful\n" : "Logout failed: " . $logout->status_line . "\n";

	# --- STEP 6: Verify SMS sent successfully ---
	if ($resp =~ /"cmd_status":"Done"/ && $resp =~ /"msgSuccess":"1"/) {

		# --- STEP 7: Save sent SMS to /var/spool/sms/sent/ ---
		my $dir = "/var/spool/sms/sent";
		make_path($dir) unless -d $dir;
		my $message_bytes = encode('UTF-8', $message);
		my $rand_str = substr(md5_hex(time().$phone.$message_bytes),0,10);
		my $filename = File::Spec->catfile($dir, "${phone}_$rand_str");

		# Prepare header
		my $timestamp = localtime();
		my $file_content = "To: $phone\nSent: $timestamp\n\n$message";

		# Write as UTF-8 bytes to avoid wide-character errors
		open my $fh, '>:encoding(UTF-8)', $filename or warn "Failed to write SMS file $filename: $!\n";
		print $fh $file_content;
		close $fh;
		print "SMS saved to $filename\n";

		$sms_busy = 0;
		return 1;
	} else {
		print "SMS gateway returned unexpected response:\n";
		print $resp . "\n";

		print "JSON decode, if valid):\n";
		eval {
			my $decoded = JSON->new->utf8->pretty->canonical->decode($resp);
			print JSON->new->utf8->pretty->canonical->encode($decoded) . "\n";
		} or print "Response was not valid JSON\n";

		$sms_busy = 0;
		die "SMS gateway error: $resp";
	}
}

# --- Function to read SMS from router ---
# --- Function to read SMS from router ---
sub read_sms {
	return if $sms_busy;

	eval {
		$sms_busy = 1;

		# --- STEP 1: Initialize session ---
		print "Initializing session with router $router\n";
		my $init = $ua->get("http://$router/index.html");
		die "Failed to init session" unless $init->is_success;
		print "Session initialized successfully\n";

		# --- STEP 2: Login to router ---
		print "Logging in as $username\n";
		my $md5pass = md5_hex($password);
		my $login = $ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content	   => "uname=$username&passwd=$md5pass",
			Referer	   => "http://$router/index.html",
			Origin	   => "http://$router"
		);
		die "Login failed" unless $login->is_success;

		my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
		die "qSessId not found" unless $qsess;
		$cookie_jar->set_cookie(0, "qSessId",	 $qsess, "/", $router);
		$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

		# --- STEP 3: Generate CSRF token ---
		my $csrf = sprintf("%06d", int(rand(999_999)));
		$ua->default_header("X-Csrf-Token" => $csrf);

		# --- STEP 4: Get SMS from inbox ---
		my $timestamp = int(time() * 1000);
		my $url = "http://$router/data.ria?CfgType=sms_action&cont=inbox&index=0&_=$timestamp";

		my $resp = $ua->get(
			$url,
			Referer             => "http://$router/controlPanel.html",
			'X-Requested-With'  => 'XMLHttpRequest'
		);
		die "SMS read request failed: " . $resp->status_line unless $resp->is_success;

		# --- STEP 5: Retrieve authorization ID (authID) ---
		my $auth_resp = $ua->get(
			"http://$router/data.ria?token=1",
			Referer => "http://$router/controlPanel.html"
		);
		die "Failed to get authID" unless $auth_resp->is_success;
		my $authID = $auth_resp->decoded_content;
		$authID =~ s/\s+//g;
		die "Empty authID" unless $authID;

		# --- STEP 6: Parse JSON response ---
		my $content = $resp->decoded_content;
		my $sms_list;
		eval { $sms_list = JSON->new->utf8->decode($content) };
		if ($@) {
			warn "Failed to decode SMS JSON: $@\n$content\n";
			$sms_busy = 0;
			return;
		}
		print "Received " . ($sms_list->{total} // 0) . " messages\n";

		# --- Prepare incoming spool directory ---
		my $incoming_dir = "/var/spool/sms/incoming";
		make_path($incoming_dir) unless -d $incoming_dir;

		# --- STEP 7: Process messages ---
		for my $key (grep { /^M\d+$/ } keys %$sms_list) {
			my $msg  = $sms_list->{$key};
			my $phone = $msg->{phone} // '';
			my $date  = $msg->{date}  // '';
			my $tag   = $msg->{tag}   // '';
			my $text  = $msg->{msg}   // '';
			my $read  = $msg->{read}  // 0;

			print "Message $key:\n";
			print "\tFrom: $phone\n";
			print "\tDate: $date\n";
			print "\tTag:  $tag\n";
			print "\tRead: $read\n";
			print "\tMessage: $text\n\n";

			# --- STEP 8: Save to spool/incoming ---
			my $safe_phone = $phone; $safe_phone =~ s/\D//g;
			my $epoch = time();
			my $file = File::Spec->catfile($incoming_dir, "${safe_phone}_${epoch}.txt");

			my $write_ok = 1;
			eval {
				open my $fh, '>:encoding(UTF-8)', $file or die $!;
				print $fh "From: $phone\nDate: $date\nTag: $tag\n\n$text\n";
				close $fh;
			};
			if ($@) {
				warn "Failed to write file $file: $@\n";
				$write_ok = 0;
			} else {
				print "Saved to $file\n";
			}

			# --- STEP 9: Delete ONLY IF saved successfully ---
			if ($write_ok) {
				my $del_payload = qq({"CfgType":"sms_action","type":"inbox","cmd":"del","tag":"$tag","authID":"$authID"});

				my $del = $ua->post(
					"http://$router/webpost.cgi",
					Content_Type     => "application/x-www-form-urlencoded; charset=UTF-8",
					Content          => $del_payload,
					Referer          => "http://$router/controlPanel.html",
					Origin           => "http://$router",
					'X-Csrf-Token'   => $csrf,
					'X-Requested-With' => 'XMLHttpRequest'
				);

				if ($del->is_success) {
					print "Deleted from router: $tag\n";
				} else {
					warn "Failed delete for $tag: " . $del->status_line . "\n";
				}
			} else {
				warn "NOT deleting $tag since write was not successful\n";
			}
		}

		# --- STEP 10: Logout ---
		my $logout_json = qq({"logout":"$qsess"});
		$ua->post(
			"http://$router/login.cgi",
			Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
			Content      => $logout_json,
			Referer      => "http://$router/controlPanel.html",
			Origin       => "http://$router"
		);

		$sms_busy = 0;
		return $sms_list;
	};
	if ($@) {
		warn "Error in read_sms: $@\n";
		$sms_busy = 0;
	}
}

# --- Start background thread to read SMS every 10 seconds ---
threads->create(sub {
	while (1) {
		read_sms();
		sleep(10);
	}
})->detach();

# --- SMTP server using Net::Server::Mail::SMTP ---
my $socket = IO::Socket::INET->new(
	LocalPort => 25,
	Listen	   => 5,
	Proto	   => 'tcp',
	Reuse	   => 1,
) or die "Unable to bind SMTP server port 25: $!";

print "SMTP SMS Gateway running on port 25...\n";

# --- Main loop: accept SMTP clients and process messages ---
while (my $client = $socket->accept()) {
	my $smtp = Net::Server::Mail::SMTP->new(socket => $client);

	# --- Capture RCPT TO addresses (phone numbers) ---
	$smtp->set_callback(RCPT => sub {
		my ($session, $rcpt) = @_;
		$rcpt =~ s/\D//g;  # remove non-digits
		$session->{_sms_to} = $rcpt;
		return 1;
	});

	# --- Capture message DATA and send SMS ---
	$smtp->set_callback(DATA => sub {
		my ($session, $data) = @_;

		my $email = Email::Simple->new($data);
		my $subject = $email->header('Subject') || '';
		my $body	  = $email->body || '';
		my $message = ($subject && $body) ? "$subject $body" : ($subject . $body);
		my $dest	  = $session->{_sms_to};

		print "Sending SMS to $dest ...\n";
		my $ok = eval { send_sms($dest, $message) };

		if ($ok) {
			print "✔ SMS to $dest sent successfully\n";
			return 1;
		} else {
			warn "❌ SMS to $dest failed: $@\n";
			$smtp->reply(421, "SMS gateway temporarily down");
			return 0;
		}
	});

	$smtp->process || next;
}
