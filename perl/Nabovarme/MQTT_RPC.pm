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
			$serial,
			$mqtt_function
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
			$message,
			$has_callback,
			$timeout,
			$d->{id}
		);

		$command_id = $d->{id};
	}
	else {
		# Insert a new command and retain its ID for all subsequent processing.
		$dbh->do(qq[INSERT INTO command_queue \
			(`serial`, `function`, `param`, `unix_time`, `state`, `has_callback`, `timeout`, `is_stateful`) \
			VALUES (?, ?, ?, UNIX_TIMESTAMP(NOW()), 'sent', ?, ?, ?)],
			undef,
			$serial,
			$mqtt_function,
			$message,
			$has_callback,
			$timeout,
			$is_stateful
		) or return 0;

		$command_id = $dbh->{mysql_insertid};
		if (!$command_id) {
			($command_id) = $dbh->selectrow_array(qq[SELECT LAST_INSERT_ID()]);
		}
	}

	return 0 if !$command_id;
	return 1 if !$callback;

	# Wait for a response belonging to this exact command row.
	my $last_param;
	my $start_time = time();

	while (1) {
		$sth = $dbh->prepare(qq[SELECT `id`, `serial`, `function`, `param`, `unix_time`, `state` \
			FROM command_queue \
			WHERE `id` = ? \
				AND `serial` = ? \
				AND `function` = ? \
				AND (`state` = 'received' OR `state` = 'timeout')]);
		$sth->execute($command_id, $serial, $mqtt_function);
		$d = $sth->fetchrow_hashref;

		if ($d) {
			if ($continuous) {
				# Continuous mode: fire the callback when the response changes.
				my $current_param = defined($d->{param}) ? $d->{param} : '';
				if (!defined($last_param) || $current_param ne $last_param) {
					$last_param = $current_param;
					my $ret = $callback->({
						serial    => $d->{serial},
						function  => $d->{function},
						param     => $d->{param},
						unix_time => $d->{unix_time}
					});

					# If the callback explicitly returns 0, abort continuous mode.
					if (defined($ret) && $ret == 0) {
						$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $command_id);
						return 1;
					}
				}

				if ($d->{state} =~ /^timeout$/i) {
					$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $command_id);
					return 0;
				}

				# --- SPECIAL CASE: Async OTA Flashing ---
				# Return the response row to 'sent' so the listener can store subsequent
				# progress responses. Avoid retransmitting the OTA payload by moving
				# last_sent one day into the future.
				# The conditional update prevents an older poll result from resetting
				# a newer response that the listener has already stored.
				if ($d->{state} eq 'received' && $d->{function} eq 'ota_upgrade') {
					$dbh->do(qq[UPDATE command_queue \
						SET `state` = 'sent', \
							`last_sent` = UNIX_TIMESTAMP() + 86400 \
						WHERE `id` = ? \
							AND `state` = 'received' \
							AND `param` = ? \
							AND COALESCE(`param`, '') NOT REGEXP '(^|&)status=(success|restarting[^&]*|error[^&]*|fail[^&]*)($|&)'],
						undef,
						$command_id,
						$last_param
					);
				}
			}
			else {
				# Standard mode: fire once, delete only this command, then return.
				$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $command_id);
				$callback->({
					serial    => $d->{serial},
					function  => $d->{function},
					param     => $d->{param},
					unix_time => $d->{unix_time}
				});

				return 0 if $d->{state} =~ /^timeout$/i;
				return 1;
			}
		}

		sleep 1;

		# Local hard timeout for continuous mode to prevent infinite hangs.
		if ($continuous && $timeout > 0 && (time() - $start_time > $timeout)) {
			$dbh->do(qq[DELETE FROM command_queue WHERE `id` = ?], undef, $command_id);
			return 0;
		}
	}
}

1;
