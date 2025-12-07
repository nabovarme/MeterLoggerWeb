#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use LWP::UserAgent;
use HTTP::Cookies;
use Digest::MD5 qw(md5_hex);
use JSON;

# -------- LOAD CONFIG FROM .env --------
my $config_file = "../.env";
open my $fh, "<", $config_file or die "Cannot open $config_file: $!";
my %config;
while (<$fh>) {
    chomp;
    next if /^\s*$/;         # skip empty lines
    next if /^\s*#/;         # skip comments
    if (/^\s*([^=]+?)\s*=\s*(.*?)\s*$/) {
        $config{$1} = $2;
    }
}
close $fh;

my $router   = $config{DLINK_ROUTER_IP}   or die "Missing ROUTER in .env\n";
my $username = $config{DLINK_ROUTER_USER}     or die "Missing USER in .env\n";
my $password = $config{DLINK_ROUTER_PASS} // "";

# -------- ARGS --------
my ($phone, $message) = @ARGV;
die "Usage: $0 <phone> <message>\n" unless $phone && $message;

# -------- UA / COOKIES --------
my $cookie_jar = HTTP::Cookies->new;
my $ua = LWP::UserAgent->new(
    agent => "Mozilla/5.0",
    cookie_jar => $cookie_jar,
    timeout => 10
);

$ua->default_header("Accept" => "application/json, text/javascript, */*; q=0.01");
$ua->default_header("Accept-Language" => "en-GB,en;q=0.9");
$ua->default_header("Connection" => "keep-alive");
$ua->default_header("X-Requested-With" => "XMLHttpRequest");

# =======================================================
# STEP 1: INIT SESSION (GET /index.html)
# =======================================================
my $init = $ua->get("http://$router/index.html");
print "Initial GET /index.html HTTP: ", $init->code, "\n";

# =======================================================
# STEP 2: LOGIN
# =======================================================
my $md5pass = md5_hex($password);
print "MD5 password: $md5pass\n";

my $login = $ua->post(
    "http://$router/login.cgi",
    Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
    Content      => "uname=$username&passwd=$md5pass",
    Referer      => "http://$router/index.html",
    Origin       => "http://$router"
);

print "Login HTTP: ", $login->code, "\n";
die "❌ Login failed\n" unless $login->is_success;

# Extract qSessId from Set-Cookie header
my ($qsess) = $login->header("Set-Cookie") =~ /qSessId=([^;]+)/;
die "❌ qSessId not found\n" unless $qsess;
print "qSessId = $qsess\n";

# Apply JS-style cookies (DWRLOGGED*)
$cookie_jar->set_cookie(0, "qSessId", $qsess, "/", $router);
$cookie_jar->set_cookie(0, "DWRLOGGEDID", $qsess, "/", $router);
$cookie_jar->set_cookie(0, "DWRLOGGEDUSER", "admin", "/", $router);
$cookie_jar->set_cookie(0, "DWRLOGGEDTIMEOUT", 300, "/", $router);

# =======================================================
# STEP 3: GET AUTHID
# =======================================================
my $auth_resp = $ua->get(
    "http://$router/data.ria?token=1",
    Referer => "http://$router/controlPanel.html"
);

die "❌ Failed to get authID\n" unless $auth_resp->is_success;

my $authID = $auth_resp->decoded_content;
$authID =~ s/\s+//g;  # remove any whitespace/newlines
die "❌ Empty authID\n" unless $authID;

print "authID: $authID\n";

# =======================================================
# STEP 4: SEND SMS
# =======================================================
# CSRF token (random 6 digits like browser JS)
my $csrf = sprintf("%06d", int(rand(999_999)));
$ua->default_header("X-Csrf-Token" => $csrf);

my $payload = {
    CfgType    => "sms_action",
    type       => "sms_send",
    msg        => $message,
    phone_list => $phone,
    authID     => $authID
};

my $json = encode_json($payload);

my $sms = $ua->post(
    "http://$router/webpost.cgi",
    Content_Type => "application/x-www-form-urlencoded; charset=UTF-8",
    Content      => $json,
    Referer      => "http://$router/controlPanel.html",
    Origin       => "http://$router"
);

print "SMS HTTP: ", $sms->code, "\n";
print "Response: ", $sms->decoded_content, "\n";

if ($sms->decoded_content =~ /Done|1/) {
    print "✔ SMS sent successfully\n";
} else {
    print "❌ SMS failed\n";
}
__END__
