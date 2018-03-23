package Nabovarme::MQTT_RPC;

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Math::Random::Secure qw(rand);
use Digest::SHA qw( sha256 hmac_sha256 );
use Proc::Pidfile;
use Time::HiRes qw( usleep );
use threads;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl );
use lib qw( /Users/loppen/Documents/stoffer/MeterLoggerWeb/perl );
use Nabovarme::Db;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

sub new {
	my $type = shift;
	my $self = {};
	
	my $config = new Config::Simple(CONFIG_FILE) || die $!;
	$self->{mqtt_host} = $config->param('mqtt_host');
	$self->{mqtt_port} = $config->param('mqtt_port');
	
	return bless $self, $type;
}

sub connect {
	my $self = shift;
	
	if ($self->{dbh} = Nabovarme::Db->my_connect) {
		$self->{mqtt} = Net::MQTT::Simple->new($self->{mqtt_host} . ':' . $self->{mqtt_port});
		return 1;
	}
	else {
		return 0;
	}
}

sub call {
	my ($self, $args) = @_;

	my $serial = $args->{serial};
	my $mqtt_function = $args->{function};
	my $message = $args->{param};
	my $callback = $args->{callback};
	
	my $quoted_serial = $self->{dbh}->quote($serial);
	my $quoted_mqtt_function = $self->{dbh}->quote($mqtt_function);
	my $quoted_message = $self->{dbh}->quote($message);
	
	my $sth = $self->{dbh}->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $quoted_serial . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		# insert into db mqtt command queue
		$self->{dbh}->do(qq[INSERT INTO command_queue2 (`serial`, `function`, `param`, `unix_time`, `state`) \
			VALUES ($quoted_serial, $quoted_mqtt_function, $quoted_message, UNIX_TIMESTAMP(NOW()), 'sent')]);
				
	}
	
	# wait for reply
	my $d = undef;
	do {
		$sth = $self->{dbh}->prepare(qq[SELECT `id`, `serial`, `function`, `param`, `unix_time`, `state` FROM command_queue2 \
			WHERE `serial` LIKE $quoted_serial AND `function` LIKE $quoted_mqtt_function AND `state` = 'received']);
		$sth->execute;
		if ($d = $sth->fetchrow_hashref) {
			$self->{dbh}->do(qq[DELETE FROM command_queue2 WHERE `id` = $d->{id}]);
			$callback->({serial => $d->{serial}, function => $d->{function}, param => $d->{param}, unix_time => $d->{unix_time}});
			return 1;
		} 	        
		sleep 1;
	} while (!$d)
	
}


1;

__END__
