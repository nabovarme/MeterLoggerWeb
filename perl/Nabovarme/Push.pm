package Nabovarme::Push;

use strict;
use warnings;
use utf8;
use LWP::UserAgent;
use JSON ();
use MIME::Base64 qw(encode_base64url decode_base64url);
use Crypt::JWT qw(encode_jwt);
use Crypt::PK::ECC;
use Crypt::PRNG qw(random_bytes);
use Crypt::Digest::SHA256 qw(sha256);
use Crypt::Mac::HMAC qw(hmac);
use Crypt::AuthEnc::GCM;
use URI;
use Nabovarme::Db;
use Nabovarme::Number::Phone;

# send_notification_to_phone
sub send_notification_to_phone {
	my ($class, $phone, $payload_args) = @_;

	unless ($payload_args && ref($payload_args) eq 'HASH') {
		warn "[Nabovarme::Push Error] Invalid arguments. Expected a HashRef for notification payload.\n";
		return 0;
	}

	# Normalize and compact phone number to match database storage format
	if ($phone) {
		my $phone_obj = Nabovarme::Number::Phone->new($phone);
		if ($phone_obj && $phone_obj->is_valid) {
			$phone = $phone_obj->compact;
		}
	}

	my %payload_data = %$payload_args;

	# Provide safe defaults for minimum required fields
	$payload_data{title} ||= 'Notification';
	$payload_data{body}  ||= '';
	$payload_data{url}   ||= '/';

	# Enforce the Web Push strict 2-action limit if actions are provided
	if ($payload_data{actions} && ref($payload_data{actions}) eq 'ARRAY') {
		my @valid_actions = splice(@{$payload_data{actions}}, 0, 2);
		$payload_data{actions} = \@valid_actions;
	}

	my $vapid_public  = $ENV{VAPID_PUBLIC_KEY}  || '';
	my $vapid_private = $ENV{VAPID_PRIVATE_KEY} || '';
	my $vapid_subject = $ENV{VAPID_SUBJECT}     || 'mailto:admin@nabovarme.dk';

	unless ($vapid_public && $vapid_private) {
		warn "[Nabovarme::Push Error] VAPID keys not configured in environment\n";
		return 0;
	}

	my $dbh = Nabovarme::Db->my_connect;
	unless ($dbh) {
		warn "[Nabovarme::Push Error] Could not connect to database\n";
		return 0;
	}

	# Query by compacted phone instead of serial
	my $sth = $dbh->prepare("SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE phone = ?");
	$sth->execute($phone);

	my $ua = LWP::UserAgent->new(timeout => 10);
	my $payload_json = JSON::encode_json(\%payload_data);
	my $sent_count = 0;

	while (my $row = $sth->fetchrow_hashref) {
		my $endpoint = $row->{endpoint};
		my $uri = URI->new($endpoint);
		my $origin = $uri->scheme . '://' . $uri->host;

		# 1. Generate RFC 8292 compliant VAPID JWT signature
		my $claims = {
			aud => $origin,
			sub => $vapid_subject,
			exp => time() + 86400,
		};

		my $pk = eval {
			my $ecc = Crypt::PK::ECC->new();
			$ecc->import_key_raw(decode_base64url($vapid_private), 'secp256r1');
			$ecc;
		};

		unless ($pk) {
			warn "[Nabovarme::Push Error] Invalid VAPID private key encoding\n";
			next;
		}

		my $jwt = eval {
			encode_jwt(
				payload => $claims,
				key     => $pk,
				alg     => 'ES256'
			);
		};

		if ($@ || !$jwt) {
			warn "[Nabovarme::Push Error] JWT signing failed: $@\n";
			next;
		}

		# 2. Encrypt Payload via ECE (RFC 8188 / RFC 8291)
		my $encrypted_body = eval {
			encrypt_payload($payload_json, $row->{p256dh}, $row->{auth});
		};

		if ($@ || !$encrypted_body) {
			warn "[Nabovarme::Push Error] Payload encryption failed for ID $row->{id}: $@\n";
			next;
		}

		# 3. Build HTTP POST Request
		my $req = HTTP::Request->new('POST', $endpoint);
		$req->header('Authorization'     => 'vapid t=' . $jwt . ', k=' . $vapid_public);
		$req->header('TTL'               => '86400');
		$req->header('Content-Encoding'  => 'aes128gcm');
		$req->header('Content-Type'      => 'application/octet-stream');
		$req->content($encrypted_body);

		# 4. Dispatch Request
		my $res = $ua->request($req);

		if ($res->is_success || $res->code == 201 || $res->code == 202) {
			$sent_count++;
		} else {
			my $code = $res->code;
			if ($code == 404 || $code == 410) {
				warn "[Nabovarme::Push Prune] Subscription ID $row->{id} expired (HTTP $code), removing.\n";
				$dbh->do("DELETE FROM push_subscriptions WHERE id = ?", undef, $row->{id});
			} else {
				warn sprintf("[Nabovarme::Push Error] Push failed to ID %s (HTTP %s): %s\n",
					$row->{id}, $code, $res->status_line);
			}
		}
	}

	# 5. Log dispatched notification to push_messages table if delivered to at least 1 device
	if ($sent_count > 0 && $phone) {
		eval {
			$dbh->do(qq[
				INSERT INTO push_messages (phone, title, message, url, devices_reached, unix_time)
				VALUES (?, ?, ?, ?, ?, ?)
			], undef, $phone, $payload_data{title}, $payload_data{body}, $payload_data{url}, $sent_count, time());
		};
		if ($@) {
			warn "[Nabovarme::Push Error] Could not save push message to push_messages: $@\n";
		}
	}

	return $sent_count;
}

# Helper: RFC 8188 / RFC 8291 AES-128-GCM ECE Payload Encryption
sub encrypt_payload {
	my ($plaintext, $user_p256dh_b64, $user_auth_b64) = @_;

	my $user_p256dh = decode_base64url($user_p256dh_b64);
	my $user_auth   = decode_base64url($user_auth_b64);

	# Ephemeral EC Key Pair Generation
	my $ephemeral_pk = Crypt::PK::ECC->new();
	$ephemeral_pk->generate_key('secp256r1');
	my $ephemeral_pub = $ephemeral_pk->export_key_raw('public');

	# User EC Key Import
	my $user_pk = Crypt::PK::ECC->new();
	$user_pk->import_key_raw($user_p256dh, 'secp256r1');

	# Shared ECDH Secret calculation
	my $shared_secret = $ephemeral_pk->shared_secret($user_pk);

	# Salt Generation (16 bytes)
	my $salt = random_bytes(16);

	# HKDF Info Key Derivation (RFC 8291)
	my $key_info  = "WebPush: info\0" . $user_p256dh . $ephemeral_pub;
	my $ikm       = hkdf_sha256($shared_secret, $user_auth, $key_info, 32);

	my $content_encryption_key = hkdf_sha256($ikm, $salt, "Content-Encoding: aes128gcm\0", 16);
	my $nonce                  = hkdf_sha256($ikm, $salt, "Content-Encoding: nonce\0", 12);

	# Record Body Construction (Padding delimiter 0x02)
	my $record = $plaintext . "\x02";

	# AES-128-GCM Encryption using CryptX API
	my $ae = Crypt::AuthEnc::GCM->new('AES', $content_encryption_key);
	$ae->iv_add($nonce);
	$ae->adata_add(''); # Required to transition GCM state machine before encrypt_add
	my $ciphertext = $ae->encrypt_add($record);
	my $tag        = $ae->encrypt_done();

	# Assemble RFC 8188 Header (Salt + Record Size + Ephemeral Key Length + Ephemeral Key + Ciphertext + Tag)
	my $rs = pack('N', 4096);
	my $idlen = pack('C', length($ephemeral_pub));
	
	return $salt . $rs . $idlen . $ephemeral_pub . $ciphertext . $tag;
}

# HKDF-SHA256 Helper Function
sub hkdf_sha256 {
	my ($ikm, $salt, $info, $length) = @_;
	my $prk = hmac('SHA256', $salt, $ikm);
	my $t = hmac('SHA256', $prk, $info . "\x01");
	return substr($t, 0, $length);
}

1;
