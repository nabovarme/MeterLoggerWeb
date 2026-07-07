package Nabovarme::APIFirmwareRebuild;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Log ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use JSON ();
use Redis ();

use Nabovarme::Db;

# Translate incoming aggregated user semantic version string into actual compiler instructions flags matching Makefile specs
sub build_flags_from_sw_version {
	my ($sw_version) = @_;
	return 'AP=1' unless defined $sw_version;

	my @flags = ('AP=1');

	# Protocol Mapping Directives
	push @flags, 'EN61107=1'        if $sw_version =~ /MC_66C/;
	push @flags, 'MC_66B=1'         if $sw_version =~ /MC_66B/;
	push @flags, 'IMPULSE=1'        if $sw_version =~ /IMPULSE/;
	push @flags, 'MC_66B=1'         if $sw_version =~ /MC-B/;
	push @flags, 'EN61107=1'        if $sw_version =~ /MC/ && $sw_version !~ /MC_66B/;

	# Logic Modifier Overrides
	push @flags, 'FLOW_METER=1'     if $sw_version =~ /FLOW_METER/;
	push @flags, 'AUTO_CLOSE=0'     if $sw_version =~ /NO_AUTO_CLOSE/;
	push @flags, 'NO_CRON=1'        if $sw_version =~ /NO_CRON/;

	# Electrical Actuator Configuration States
	push @flags, 'THERMO_NO=1'      if $sw_version =~ /THERMO_NO/;
	push @flags, 'THERMO_ON_AC_2=1' if $sw_version =~ /THERMO_ON_AC_2/;
	push @flags, 'LED_ON_AC=1'      if $sw_version =~ /LED_ON_AC/;
	push @flags, 'AC_TEST=1'        if $sw_version =~ /AC_TEST/;

	# Diagnostics / Mock Output Variables
	push @flags, 'DEBUG=1'                if $sw_version =~ /DEBUG/ && $sw_version !~ /DEBUG_NO_METER/ && $sw_version !~ /DEBUG_STACK_TRACE/;
	push @flags, 'DEBUG=1 DEBUG_NO_METER=1' if $sw_version =~ /NO_METER/;
	push @flags, 'DEBUG_STACK_TRACE=1'    if $sw_version =~ /DEBUG_STACK_TRACE/;

	return join(' ', @flags);
}

sub handler {
	my $r = shift;
	my ($dbh, $sth);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		$r->headers_out->set('Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0');
		$r->headers_out->set('Pragma' => 'no-cache');
		$r->headers_out->set('Expires' => '0');
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		if ($r->method ne 'POST') {
			$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Method not allowed" }));
			return Apache2::Const::OK;
		}

		# --- PARSE SECURED PARAMS FROM MEMORY PRESERVED QUERY STRING ---
		my %params;
		my $args_string = $r->args || '';
		foreach my $pair (split(/[&;]/, $args_string)) {
			my ($key, $val) = split(/=/, $pair, 2);
			next unless defined $key;
			$val = '' unless defined $val;
			$key =~ tr/+/ /; $key =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
			$val =~ tr/+/ /; $val =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
			$params{$key} = $val;
		}

		my $serial    = $params{serial};
		my $modifiers = $params{sw_version_modifiers} || 'STANDARD';

		if (!defined $serial || $serial eq '') {
			$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Missing target serial identity parameter context" }));
			return Apache2::Const::OK;
		}

		my $sql = q[SELECT info, sw_version FROM meters WHERE serial = ? AND enabled = 1 LIMIT 1];
		$sth = $dbh->prepare($sql);
		$sth->execute($serial);
		my $meter = $sth->fetchrow_hashref;

		if (!$meter) {
			$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Active targeted meter context not found" }));
			return Apache2::Const::OK;
		}

		my $base_version = $meter->{sw_version} || '1.0';
		my $custom_version = "${base_version}-CUSTOM-${modifiers}";

		my $redis;
		eval {
			$redis = Redis->new(server => "$ENV{REDIS_HOST}:$ENV{REDIS_PORT}");
		};
		if ($@) {
			$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Redis message broker engine connectivity failure" }));
			return Apache2::Const::OK;
		}

		my $batch_id = "custom-" . time();

		$redis->set("firmware_jobs_total:$batch_id", 1);
		$redis->set("firmware_jobs_completed:$batch_id", 0);
		$redis->set("firmware_jobs_skipped:$batch_id", 0);
		$redis->set("firmware_jobs_failed:$batch_id", 0);
		$redis->rpush("firmware_active_batches", $batch_id);

		my $job_payload = {
			serial       => $serial,
			info         => $meter->{info} || '',
			trigger_time => time(),
			version      => $custom_version,
			build_flags  => build_flags_from_sw_version($custom_version),
			batch_id     => $batch_id
		};

		$redis->rpush("firmware_build_queue", JSON::encode_json($job_payload));

		$r->print(
			JSON->new->utf8->canonical->encode({ success => 1, batch_id => $batch_id })
		);

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

1;
