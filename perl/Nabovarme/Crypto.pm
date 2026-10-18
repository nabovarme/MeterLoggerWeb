package Nabovarme::Crypto;

use strict;
use warnings;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Data::Dumper;
use Sys::Syslog;

use Nabovarme::Db;

# --- Config from environment ---
my $config_cached_time = $ENV{'CRYPTO_KEY_CACHE_TIME'} // 3600;   # default 1 hour

sub new {
	my $class = shift;

	my $self = {};
	$self->{dbh} = Nabovarme::Db->my_connect || die $!;
	$self->{key_cache} = undef;

	return bless $self, $class;
}


sub decrypt_topic_message_for_serial {
	my ($self, $topic, $message, $meter_serial, $explicit_key) = @_;

	return undef unless defined $message;
	return undef unless $message =~ /\A(.{32})(.{16})(.+)\z/s;

	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;

	my $key;

	if (defined $explicit_key) {
		$key = $explicit_key;
	}
	elsif (
		exists($self->{key_cache}->{$meter_serial})
		&& $self->{key_cache}->{$meter_serial}->{cached_time}
			> (time() - $config_cached_time)
	) {
		$key = $self->{key_cache}->{$meter_serial}->{key};
	}
	else {
		my $sth = $self->{dbh}->prepare(qq[
			SELECT `key`
			FROM meters
			WHERE serial = ?
			LIMIT 1
		]);

		$sth->execute($meter_serial);

		if (my $d = $sth->fetchrow_hashref) {
			$key = $d->{key};

			$self->{key_cache}->{$meter_serial} = {
				key => $key,
				cached_time => time(),
			};
		}
	}

	return undef unless defined $key && length $key;

	my $sha256 = sha256(pack('H*', $key));
	my $aes_key = substr($sha256, 0, 16);
	my $hmac_sha256_key = substr($sha256, 16, 16);

	return undef unless $mac eq hmac_sha256(
		$topic . $iv . $ciphertext,
		$hmac_sha256_key,
	);

	my $m = Crypt::Mode::CBC->new('AES');
	my $cleartext = $m->decrypt($ciphertext, $aes_key, $iv);

	$cleartext =~ s/[\x00\s]+$//;
	$cleartext .= '';

	return $cleartext;
}

sub invalidate_key_cache {
	my ($self, $meter_serial) = @_;

	delete $self->{key_cache}->{$meter_serial};
}

1;
