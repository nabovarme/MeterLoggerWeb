#!/usr/bin/perl -w

use strict;
use warnings;
use Carp;
use Encode qw(encode decode);
use Email::Simple;
use Data::Dumper;

use Net::Server::Mail::SMTP;
use IO::Socket::INET;

use LWP::UserAgent;
use HTTP::Cookies;
use Digest::MD5 qw(md5_hex);
use JSON;

use constant USER  => 'smsd';
use constant GROUP => 'smsd';

$| = 1;  # Autoflush STDOUT

# --- Read configuration from environment ---
my $router   = $ENV{DLINK_ROUTER_IP}   or die "Missing DLINK_ROUTER_IP env variable\n";
my $username = $ENV{DLINK_ROUTER_USER} or die "Missing DLINK_ROUTER_USER env variable\n";
my $password = $ENV{DLINK_ROUTER_PASS} // "";

# --- Initialize HTTP client for SMS ---
my $cookie_jar = HTTP::Cookies->new;
my $ua = LWP::UserAgent->new(
	agent	   => "Mozilla/5.0",
	cookie_jar  => $cookie_jar,
	timeout	 => 10,
);
$ua->default_header("Accept"		   => "application/json, text/javascript, */*; q=0.01");
$ua->default_header("Accept-Language"  => "en-GB,en;q=0.9");
$ua->default_header("Connection"	   => "keep-alive");
$ua->default_header("X-Requested-With" => "XMLHttpRequest");

# --- Define SMS sending function ---
sub send_sms {
	my ($phone, $message) = @_;
	die "Missing phone or message\n" unless $phone && $message;

	# --- STEP 1: INIT SESSION ---
	my $init = $ua->get("http://$router/index.html");
	unless ($init->is_success) {
		warn "HTTP GET failed: " . $init->status_line;
		die "Failed to init session\n";
	}

	# --- STEP 2: LOGIN ---
	my $md5pass = md5_hex($password);
	my $login = $ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content	  => "uname=$username&passwd=$md5pass",
		Referer	  => "http://$router/index.html",
		Origin	   => "http://$router"
	);
	die "Login failed\n" unless $login->is_success;

	# Extract qSessId
	my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
	die "qSessId not found\n" unless $qsess;
	$cookie_jar->set_cookie(0, "qSessId",	 $qsess, "/", $router);
	$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);

	# --- STEP 3: GET AUTHID ---
	my $auth_resp = $ua->get("http://$router/data.ria?token=1",
		Referer => "http://$router/controlPanel.html");
	die "Failed to get authID\n" unless $auth_resp->is_success;
	my $authID = $auth_resp->decoded_content;
	$authID =~ s/\s+//g;
	die "Empty authID\n" unless $authID;

	# --- STEP 4: SEND SMS ---
	my $csrf = sprintf("%06d", int(rand(999_999)));
	$ua->default_header("X-Csrf-Token" => $csrf);

	my $payload = {
		CfgType	 => "sms_action",
		type		=> "sms_send",
		msg		 => $message,
		phone_list  => $phone,
		authID	  => $authID
	};
	my $json = encode_json($payload);

	my $sms = $ua->post(
		"http://$router/webpost.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content	  => $json,
		Referer	  => "http://$router/controlPanel.html",
		Origin	   => "http://$router"
	);

	die "SMS HTTP failed: " . $sms->code unless $sms->is_success;
	my $resp = $sms->decoded_content;

	# --- LOGOUT always, regardless of success ---
	my $logout_json = qq({"logout":"$qsess"});
	$ua->post(
		"http://$router/login.cgi",
		Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
		Content      => $logout_json,
		Referer      => "http://$router/controlPanel.html",
		Origin       => "http://$router"
	);

	# --- Check for success ---
	if ($resp =~ /"cmd_status":"Done"/ && $resp =~ /"msgSuccess":"1"/) {
		return 1;
	} else {
		die "SMS gateway error: $resp";
	}
}

# --- SMTP server using Net::Server::Mail::SMTP ---
my $socket = IO::Socket::INET->new(
	LocalPort => 25,
	Listen	=> 5,
	Proto	 => 'tcp',
	Reuse	 => 1,
) or die "Unable to bind SMTP server port 25: $!";

print "SMTP SMS Gateway running on port 25...\n";

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
		my $body	= $email->body || '';
		my $message = ($subject && $body) ? "$subject $body" : ($subject . $body);
		my $dest	= $session->{_sms_to};

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
