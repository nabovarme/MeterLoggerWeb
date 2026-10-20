package Nabovarme::FirmwareSupport;

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(firmware_supports);

# RPCs already present in firmware version 967.
my %initial_rpc = map { $_ => 1 } qw(
	ap_status
	clear_cron
	close
	cron
	crypto
	mem
	open
	open_until
	open_until_delta
	ping
	reset_reason
	reconnect
	rssi
	scan
	set_cron
	set_pwd
	set_ssid
	ssid
	start_ap
	status
	stop_ap
	uptime
	version
	wifi_status
);

# RPC additions and removals after firmware version 967.
# Format: [firmware version, RPC name, supported].
my @changes = (
	[ 974,  'vdd',                1 ],
	[ 1004, 'last_energy_kwh',    1 ],
	[ 1005, 'last_energy_kwh',    0 ],
	[ 1005, 'energy_kwh',         1 ],
	[ 1011, 'energy_kwh',         0 ],
	[ 1033, 'set_ssid_pwd',       1 ],
	[ 1036, 'off',                0 ],
	[ 1036, 'pwm',                0 ],
	[ 1036, 'test',               0 ],
	[ 1091, 'exc_test',           1 ],
	[ 1145, 'exc_test',           0 ],
	[ 1145, 'stack_trace',        1 ],
	[ 1259, 'restart',            1 ],
	[ 1347, 'flash_size',         1 ],
	[ 1349, 'flash_id',           1 ],
	[ 1350, 'disconnect_count',   1 ],
	[ 1350, 'icmp_ping',           1 ],
	[ 1353, 'network_quality',    1 ],
	[ 1355, 'icmp_ping',           0 ],
	[ 1446, 'chip_id',            1 ],
	[ 1451, 'set_ap_mesh_pwd',    1 ],
	[ 1468, 'test_ssid_pwd',      1 ],
	[ 1484, 'start_fallback_ap',  1 ],
	[ 1503, 'fallback_status',    1 ],
	[ 1529, 'ota_upgrade',        1 ],
	[ 1534, 'set_key',            1 ],
	[ 1634, 'read_stack_trace',   1 ],
	[ 1695, 'ota_update',         1 ],
	[ 1695, 'ota_upgrade',        0 ],
	[ 1697, 'ota_update',         0 ],
	[ 1697, 'ota_upgrade',        1 ],
	[ 1698, 'ota_update',         1 ],
	[ 1698, 'ota_upgrade',        0 ],
	[ 1754, 'set_mqtt_host',      1 ],
	[ 1774, 'crypto',             0 ],
);

sub firmware_supports {
	my ($version, $command) = @_;

	return 0 unless defined $version && $version =~ /^\d+$/;
	return 0 unless defined $command && length $command;

	my %supported = %initial_rpc;

	for my $change (@changes) {
		my ($change_version, $name, $is_supported) = @$change;

		last if $change_version > $version;

		if ($is_supported) {
			$supported{$name} = 1;
		}
		else {
			delete $supported{$name};
		}
	}

	return $supported{$command} ? 1 : 0;
}

1;
