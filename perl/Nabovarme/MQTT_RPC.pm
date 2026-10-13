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

	# OTA response topics contain the meter serial and function, but no queue ID.
	# Hold a per-meter advisory lock for the entire OTA RPC call so concurrent
	# callers cannot create competing OTA commands for the same meter.
	if (defined($args->{function}) && $args->{function} eq 'ota_upgrade'
		&& defined($args->{serial}) && $args->{serial} ne '') {
		my $dbh = $self->{dbh};
		return 0 if !$dbh;

		my $lock_name = 'Nabovarme:OTA:' . $args->{serial};
		my ($got_lock) = $dbh->selectrow_array(
			qq[SELECT GET_LOCK(?, 0)],
			undef,
			$lock_name
		);

		if (!$got_lock) {
			warn "MQTT_RPC: OTA command already active for meter $args->{serial}.\n";
			return 0;
		}

		my ($result, $error);
		my $ok = eval {
			$result = $self->_call_unlocked($args);
			1;
		};
		$error = $@;

		# Always release the lock, including when a callback or DB operation dies.
		eval {
			$dbh->selectrow_array(qq[SELECT RELEASE_LOCK(?)], undef, $lock_name);
		};

		die $error if !$ok;
		return $result;
	}

	return $self->_call_unlocked($args);
}

sub _call_unlocked {
	my ($self, $args) = @_;

	my $serial = $args->{serial};
	my $mqtt_function = $args->{function};
	my $message = defined($args->{param}) ? $args->{param} : '';
	my $callback = $args->{callback};
	my $timeout = $args->{timeout} || 0;
	my $is_stateful = $args->{stateful} ? 1 : 0;
	my $continuous = $args->{continuous} ? 1 : 0;
	my $dbh = $self->{dbh};

	return 0 if !$dbh;
	return 0 if !defined($serial) || $serial eq '';
	return 0 if !defined($mqtt_function) || $mqtt_function eq '';

	# Do not enqueue commands for unknown meters.
	my ($meter_id) = $dbh->selectrow_array(
		qq[SELECT `id` FROM meters WHERE serial = ? LIMIT 1],
		undef,
		$serial
	);

	return 0 if !defined($meter_id);

	# OTA replies do not carry a command ID. Allow only one active OTA command
	# per meter so its asynchronous replies cannot be assigned to another call.
	if ($mqtt_function eq 'ota_upgrade') {
		my ($active_id) = $dbh->selectrow_array(
			qq[SELECT `id` FROM command_queue \
				WHERE `serial` = ? \
					AND `function` = ? \
					AND `state` IN ('sent', 'received') \
				ORDER BY `id` ASC \
				LIMIT 1],
			undef,
			$serial, $mqtt_function
		);

		if (defined($active_id)) {
			warn "MQTT_RPC: OTA command already active for meter $serial (command $active_id).\n";
			return 0;
		}
	}

	my $command_id;
	my $d;
	my $sth;

	# Deduplicate ONLY if stateless (is_stateful == 0).
	if (!$is_stateful) {
		$sth = $dbh->prepare(qq[SELECT `id` FROM command_queue \
			WHERE `serial` = ? \
				AND `function` = ? \
				AND `state` = 'sent' \
				AND `is_stateful` = 0 \
			LIMIT 1]);
		$sth->execute($serial, $mqtt_function);
		$d = $sth->fetchrow_hashref;
	}

	my $has_callback = $callback ? 1 : 0;

	if ($d) {
		# Update the existing stateless command.
		$dbh->do(qq[UPDATE command_queue \
			SET `param` = ?, \
				`unix_time` = UNIX_TIMESTAMP(NOW()), \
				`has_callback` = ?, \
				`timeout` = ? \
			WHERE `id` = ?],
			undef,
			$message, $has_callback,
			$timeout, $d->{id}
		);

		$command_id = $d->{id};
	}
	else {
		# Insert a new command and retain its ID for all subsequent processing.
		$dbh->do(qq[INSERT INTO command_queue \
			(`serial`, `function`, `param`, `unix_time`, `state`, `has_callback`, `timeout`, `is_stateful`) \
			VALUES (?, ?, ?, UNIX_TIMESTAMP(NOW()), 'sent', ?, ?, ?)],
			undef,
			$serial, $mqtt_function,
			$message, $has_callback,
			$timeout, $is_stateful
		) or return 0;

		$command_id = $dbh->{mysql_insertid};
		if (!$command_id) {
			($command_id) = $dbh->selectrow_array(qq[SELECT LAST_INSERT_ID()]);
		}
	}

	return 0 if !$command_id;
	return 1 if !$callback;

	# Wait for responses belonging to this exact command row using the new dedicated response table.
	my $start_time = time();

	while (1) {
		$sth = $dbh->prepare(qq[
			SELECT cr.`id` AS resp_id, cr.`param`, cr.`unix_time`, cq.`state`
			FROM command_queue cq
			LEFT JOIN command_responses cr ON cq.`id` = cr.`command_id`
			WHERE cq.`id` = ?
				AND (cr.`id` IS NOT NULL OR cq.`state` = 'timeout')
			ORDER BY cr.`id` ASC
			LIMIT 1
		]);
		$sth->execute($command_id);
		$d = $sth->fetchrow_hashref;

		if ($d) {
			if (defined $d->{resp_id}) {
				# Pop the oldest response sequentially from the inbound queue buffer
				$dbh->do(qq[DELETE FROM command_responses WHERE `id` = ?], undef, $d->{resp_id});

				my $ret = 1;
				if ($continuous) {
					$ret = $callback->({
						serial    => $serial,
						function  => $mqtt_function,
						param     => $d->{param},
						unix_time => $d->{unix_time}
					});
				}
				else {
					$callback->({
						serial    => $serial,
						function  => $mqtt_function,
						param     => $d->{param},
						unix_time => $d->{unix_time}
					});
					$ret = 0; # Force exit for single-shot commands
				}

				if (!$continuous || (defined($ret) && $ret == 0)) {
					$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $command_id);
					# The CASCADE foreign key will clean this up, but explicit cleanup is safer
					$dbh->do(qq[DELETE FROM command_responses WHERE `command_id` = ?], undef, $command_id);
					return 1;
				}

				# If continuous mode and the callback returned true (keep listening),
				# immediately fetch the next queued event instead of sleeping.
				next;
			}
			elsif ($d->{state} =~ /^timeout$/i) {
				$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $command_id);
				$dbh->do(qq[DELETE FROM command_responses WHERE `command_id` = ?], undef, $command_id);
				return 0;
			}
		}

		sleep 1;

		# Local hard timeout for continuous mode to prevent infinite hangs.
		if ($continuous && $timeout > 0 && (time() - $start_time > $timeout)) {
			$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $command_id);
			$dbh->do(qq[DELETE FROM command_responses WHERE `command_id` = ?], undef, $command_id);
			return 0;
		}
	}
}

1;
