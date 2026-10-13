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
		my $start_time = time();

		do {
			# Fetch responses iteratively from the dedicated stream table, resolving dropped messages
			$sth = $self->{dbh}->prepare(qq[
				SELECT cr.id AS resp_id, cr.param AS cr_param, cr.unix_time AS cr_unix_time, cq.state AS cq_state, cq.id AS command_id
				FROM command_queue cq
				LEFT JOIN command_responses cr ON cq.id = cr.command_id
				WHERE cq.serial = ? AND cq.function = ?
				AND (cr.id IS NOT NULL OR cq.state = 'timeout')
				ORDER BY cr.id ASC LIMIT 1
			]);
			$sth->execute($serial, $mqtt_function);

			if ($d = $sth->fetchrow_hashref) {
				if (defined $d->{resp_id}) {
					# Pop the processed message off the queue immediately
					$self->{dbh}->do(qq[DELETE FROM command_responses WHERE id = ?], undef, $d->{resp_id});

					my $ret = 1;
					if ($continuous) {
						$ret = $callback->({serial => $serial, function => $mqtt_function, param => $d->{cr_param}, unix_time => $d->{cr_unix_time}});
					} else {
						$callback->({serial => $serial, function => $mqtt_function, param => $d->{cr_param}, unix_time => $d->{cr_unix_time}});
						$ret = 0;
					}

					if (!$continuous || (defined $ret && $ret == 0)) {
						$self->{dbh}->do(qq[DELETE FROM command_queue WHERE id = ?], undef, $d->{command_id});
						return 1;
					}

					# Immediately cycle to process the next response if there's a backlog (no sleep needed)
					next;
				}
				elsif ($d->{cq_state} =~ /^timeout$/i) {
					$self->{dbh}->do(qq[DELETE FROM command_queue WHERE id = ?], undef, $d->{command_id});
					return 0;
				}
			}

			usleep(100_000); # 100ms ultra-fast poll for highly responsive continuous streams

			# Local hard timeout for continuous mode to prevent infinite hangs
			if ($continuous && $timeout > 0 && (time() - $start_time > $timeout)) {
				$self->{dbh}->do(qq[DELETE FROM command_queue WHERE serial = ? AND function = ?], undef, $serial, $mqtt_function);
				return 0;
			}

		} while ($continuous ? 1 : !$d);
	}
	return 1;
}

1;
