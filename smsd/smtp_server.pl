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
use JSON;
use File::Path qw(make_path);
use File::Spec;

use constant USER  => 'smsd';
use constant GROUP => 'smsd';

$| = 1;  # Autoflush STDOUT

$Data::Dumper::Useqq = 0;       # don’t escape non-ASCII
$Data::Dumper::Terse = 1;       # avoid $VAR1 = ...
$Data::Dumper::Quotekeys = 0;   # don’t quote hash keys unnecessarily

# --- Read configuration from environment ---
my $router   = $ENV{DLINK_ROUTER_IP}   or die "Missing DLINK_ROUTER_IP env variable\n";
my $username = $ENV{DLINK_ROUTER_USER} or die "Missing DLINK_ROUTER_USER env variable\n";
my $password = $ENV{DLINK_ROUTER_PASS} // "";

# --- Initialize HTTP client for SMS with cookies and headers ---
my $cookie_jar = HTTP::Cookies->new;
my $ua = LWP::UserAgent->new(
	agent	   => "Mozilla/5.0",
	cookie_jar => $cookie_jar,
	timeout	   => 10,
);
$ua->default_header("Accept"		   => "application/json, text/javascript, */*; q=0.01");
$ua->default_header("Accept-Language" => "en-GB,en;q=0.9");
$ua->default_header("Connection"	   => "keep-alive");
$ua->default_header("X-Requested-With" => "XMLHttpRequest");

# --- Function to send SMS via the router ---
sub send_sms {
	my ($phone, $message) = @_;
	die "Missing phone or message\n" unless $phone && $message;

	# --- STEP 0: Ensure message is flagged as UTF-8 internally ---
	unless (is_utf8($message)) {
		print "DEBUG: Message is NOT flagged as UTF-8 internally, decoding...\n";
		$message = decode('UTF-8', $message);
	} else {
		print "DEBUG: Message is already flagged as UTF-8 internally\n";
	}
	print "DEBUG: Message hex (first 50 chars): " . join(" ", unpack("H2" x length($message), $message)) . "\n";

	# --- STEP 1: Initialize session ---
	print "DEBUG: Initializing session with router $router\n";
	my $init = $ua->get("http://$router/index.html");
	unless ($init->is_success) {
		warn "HTTP GET failed: " . $init->status_line;
		die "Failed to init session\n";
	}
	print "DEBUG: Session initialized successfully\n";

	# --- STEP 2: Login to router ---
	print "DEBUG: Logging in as $username\n";
	my $md5pass = md5_hex($password);
	my $login = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content	   => "uname=$username&passwd=$md5pass",
		Referer	   => "http://$router/index.html",
		Origin	   => "http://$router"
	);
	die "Login failed\n" unless $login->is_success;
	print "DEBUG: Login HTTP response code: " . $login->code . "\n";
	print "DEBUG: Login Set-Cookie: " . ($login->header("Set-Cookie") // '') . "\n";

	# --- Extract session ID from login response ---
	my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
	die "qSessId not found\n" unless $qsess;
	print "DEBUG: qSessId obtained: $qsess\n";
	$cookie_jar->set_cookie(0, "qSessId",	 $qsess, "/", $router);
	$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

	# --- STEP 3: Retrieve authorization ID (authID) ---
	print "DEBUG: Fetching authID\n";
	my $auth_resp = $ua->get("http://$router/data.ria?token=1",
		Referer => "http://$router/controlPanel.html");
	die "Failed to get authID\n" unless $auth_resp->is_success;
	my $authID = $auth_resp->decoded_content;
	$authID =~ s/\s+//g;
	die "Empty authID\n" unless $authID;
	print "DEBUG: authID obtained: $authID\n";

	# --- STEP 4: Send SMS ---
	print "DEBUG: Sending SMS payload\n";
	my $csrf = sprintf("%06d", int(rand(999_999)));
	$ua->default_header("X-Csrf-Token" => $csrf);

	my $payload = {
		CfgType	  => "sms_action",
		type	  => "sms_send",
		msg		  => $message,
		phone_list => $phone,
		authID	  => $authID
	};
	print "DEBUG: SMS payload: " . Dumper($payload) . "\n";
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
		print "DEBUG: SMS POST failed: " . $sms->status_line . "\n";
		print "DEBUG: Response content: " . $sms->decoded_content . "\n";
		die "SMS HTTP failed: " . $sms->code;
	}
	my $resp = $sms->decoded_content;

	# --- STEP 5: Logout from router session ---
	print "DEBUG: Logging out session $qsess\n";
	my $logout_json = qq({"logout":"$qsess"});
	my $logout = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content	   => $logout_json,
		Referer	   => "http://$router/controlPanel.html",
		Origin	   => "http://$router"
	);
	print $logout->is_success ? "DEBUG: Logout successful\n" : "DEBUG: Logout failed: " . $logout->status_line . "\n";

	# --- STEP 6: Verify SMS sent successfully ---
	if ($resp =~ /"cmd_status":"Done"/ && $resp =~ /"msgSuccess":"1"/) {

		# --- STEP 7: Save sent SMS to /var/spool/sms/sent/ ---
		my $dir = "/var/spool/sms/sent";
		make_path($dir) unless -d $dir;
		my $message_bytes = encode('UTF-8', $message);
		my $rand_str = substr(md5_hex(time().$phone.$message_bytes),0,10);
		my $filename = File::Spec->catfile($dir, "${phone}_$rand_str");

		# Write as UTF-8 bytes to avoid wide-character errors
		open my $fh, '>:encoding(UTF-8)', $filename or warn "Failed to write SMS file $filename: $!\n";
		print $fh $message;
		close $fh;
		print "DEBUG: SMS saved to $filename\n";

		return 1;
	} else {
		die "SMS gateway error: $resp";
	}
}

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
