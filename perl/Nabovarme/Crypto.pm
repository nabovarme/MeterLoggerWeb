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
	my ($self, $topic, $message, $meter_serial) = @_;

	# Safely handle empty LWT messages (e.g. /offline/ topic)
	if (defined $topic && $topic =~ m!/offline/! && (!defined $message || length($message) == 0)) {
		return '';
	}

	# Ensure $message is defined and structured as MAC (32) + IV (16) + Ciphertext
	if (!defined $message || $message !~ /^(.{32})(.{16})(.+)/s) {
		return undef;
	}

	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;

	for my $attempt (1 .. 2) {
		my $key = '';

		if ($attempt == 1 &&
			exists($self->{key_cache}->{$meter_serial}) &&
			$self->{key_cache}->{$meter_serial}->{cached_time} > (time() - $config_cached_time)) {
			$key = $self->{key_cache}->{$meter_serial}->{key} || '';
		}
		else {
			delete $self->{key_cache}->{$meter_serial};

			my $sth = $self->{dbh}->prepare(
				qq[SELECT `key` FROM meters WHERE serial = ] .
				$self->{dbh}->quote($meter_serial) .
				qq[ LIMIT 1]
			);
			$sth->execute;

			if ($sth->rows) {
				my $d = $sth->fetchrow_hashref;
				$key = $d->{key} || '';

				if ($key) {
					$self->{key_cache}->{$meter_serial}->{key} = $key;
					$self->{key_cache}->{$meter_serial}->{cached_time} = time();
				}
			}
		}

		last unless $key;

		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			my $m = Crypt::Mode::CBC->new('AES');
			my $cleartext = eval { $m->decrypt($ciphertext, $aes_key, $iv) };

			if (defined $cleartext) {
				# Remove trailing nulls and whitespace
				$cleartext =~ s/[\x00\s]+$//;
				return $cleartext;
			}
		}

		# Cached key may be stale; retry once with a fresh database lookup
		delete $self->{key_cache}->{$meter_serial};
	}

	return undef;
}

1;
