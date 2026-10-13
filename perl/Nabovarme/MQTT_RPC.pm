package Nabovarme::MQTT_RPC;

use strict;
use Data::Dumper;
use Sys::Syslog;
use DBI;
use Time::HiRes qw( usleep );

use Nabovarme::Db;

sub new {
	my $type = shift;
	my $self = {};
	
	return bless $self, $type;
}

sub connect {
	my $self = shift;
	
	if ($self->{dbh} = Nabovarme::Db->my_connect) {
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
	my $timeout = $args->{timeout} || 0;
	my $is_stateful = $args->{stateful} ? 1 : 0;
	my $continuous = $args->{continuous} ? 1 : 0;
	
	my $quoted_serial = $self->{dbh}->quote($serial);
	my $quoted_mqtt_function = $self->{dbh}->quote($mqtt_function);
	my $quoted_message = $self->{dbh}->quote($message);
	my $quoted_timeout = $self->{dbh}->quote($timeout);
	my $quoted_stateful = $self->{dbh}->quote($is_stateful);
	my $has_callback = $callback ? 1 : 0;
	
	my $d = undef;

	my $sth = $self->{dbh}->prepare(qq[SELECT `id` FROM meters WHERE serial = ] . $quoted_serial . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		# Deduplicate ONLY if stateless (is_stateful == 0)
		if (!$is_stateful) {
			$sth = $self->{dbh}->prepare(qq[SELECT `id` FROM command_queue \
				WHERE serial = $quoted_serial \
					AND `function` = $quoted_mqtt_function \
					AND `state` = 'sent' \
					AND `is_stateful` = 0 \
				LIMIT 1]);
			$sth->execute;
			$d = $sth->fetchrow_hashref;
		}

		if ($d) {
			# Update existing stateless command
			$self->{dbh}->do(qq[UPDATE command_queue \
				SET `param` = $quoted_message, \
					`unix_time` = UNIX_TIMESTAMP(NOW()), \
					`has_callback` = $has_callback, \
					`timeout` = $quoted_timeout \
				WHERE `id` = ] . $d->{id}
			);
		}
		else {
			# Insert new command
			$self->{dbh}->do(qq[INSERT INTO command_queue (`serial`, `function`, `param`, `unix_time`, `state`, `has_callback`, `timeout`, `is_stateful`) \
				VALUES ($quoted_serial, $quoted_mqtt_function, $quoted_message, UNIX_TIMESTAMP(NOW()), 'sent', $has_callback, $quoted_timeout, $quoted_stateful)]);
		}
	}
	
	if ($callback) {
		# wait for reply
		my $last_param = '';
		my $start_time = time();

		do {
			$sth = $self->{dbh}->prepare(qq[SELECT `id`, `serial`, `function`, `param`, `unix_time`, `state` FROM command_queue \
				WHERE `serial` LIKE $quoted_serial AND `function` LIKE $quoted_mqtt_function AND (`state` = 'received' OR `state` = 'timeout')]);
			$sth->execute;
			if ($d = $sth->fetchrow_hashref) {
				if ($continuous) {
					# Continuous mode: Fire callback on every param change
					if ($d->{param} ne $last_param) {
						$last_param = $d->{param};
						my $ret = $callback->({serial => $d->{serial}, function => $d->{function}, param => $d->{param}, unix_time => $d->{unix_time}});
						
						# If the callback explicitly returns 0, abort the continuous loop and cleanup
						if (defined $ret && $ret == 0) {
							$self->{dbh}->do(qq[DELETE FROM command_queue WHERE `id` = $d->{id}]);
							return 1;
						}
					}
					if ($d->{state} =~ /^timeout$/i) {
						$self->{dbh}->do(qq[DELETE FROM command_queue WHERE `id` = $d->{id}]);
						return 0;
					}
					
					# --- SPECIAL CASE: Async OTA Flashing ---
					# Return the command to 'sent' so asynchronous progress messages can
					# continue to be received without retransmitting the heavy OTA payload.
					#
					# Only update the row if the response is still the one we just processed.
					# mqtt_listener may have stored a newer response since our SELECT.
					if ($d->{state} eq 'received' && $d->{function} eq 'ota_upgrade') {
						my $quoted_param = $self->{dbh}->quote(
							defined($d->{param}) ? $d->{param} : ''
						);

						$self->{dbh}->do(qq[UPDATE command_queue \
							SET `state` = 'sent', \
								`last_sent` = UNIX_TIMESTAMP() + 86400 \
							WHERE `id` = $d->{id} \
								AND `state` = 'received' \
								AND `param` = $quoted_param]);
					}
				}
				else {
					# Standard mode (Legacy): Fire once, delete immediately, and return
					$self->{dbh}->do(qq[DELETE FROM command_queue WHERE `id` = $d->{id}]);
					$callback->({serial => $d->{serial}, function => $d->{function}, param => $d->{param}, unix_time => $d->{unix_time}});
					if ($d->{state} =~ /^timeout$/i) {
						return 0;
					}
					else {
						return 1;
					}
				}
			}
			sleep 1;

			# Local hard timeout for continuous mode to prevent infinite hangs
			if ($continuous &&$timeout > 0 && (time() - $start_time > $timeout)) {
				if ($d && $d->{id}) {
					$self->{dbh}->do(qq[DELETE FROM command_queue WHERE `id` = $d->{id}]);
				} else {
					$self->{dbh}->do(qq[DELETE FROM command_queue WHERE `serial` = $quoted_serial AND `function` = $quoted_mqtt_function]);
				}
				return 0;
			}

		} while ($continuous ? 1 : !$d)
	}
	return 1;
}

1;
