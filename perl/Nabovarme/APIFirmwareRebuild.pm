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

	# Strict Protocol Mapping Target Parsing (README compliance verification boundaries)
	if ($sw_version =~ /\bEN61107\b/) {
		push @flags, 'EN61107=1';
	}
	elsif ($sw_version =~ /\bMC_66B\b/) {
		push @flags, 'MC_66B=1';
	}
	elsif ($sw_version =~ /\bIMPULSE\b/) {
		push @flags, 'IMPULSE=1';
	}

	# Logic Modifier Overrides
	push @flags, 'FLOW_METER=1'     if $sw_version =~ /\bFLOW_METER\b/;
	push @flags, 'AUTO_CLOSE=0'     if $sw_version =~ /\bNO_AUTO_CLOSE\b/;
	push @flags, 'NO_CRON=1'        if $sw_version =~ /\bNO_CRON\b/;

	# Synchronized Actuator State Flag Dictionary Map
	push @flags, 'THERMO_NO=1'      if $sw_version =~ /\bTHERMO_NO\b/;
	push @flags, 'THERMO_NO=0'      if $sw_version =~ /\bTHERMO_NC\b/;

	push @flags, 'THERMO_ON_AC_2=1' if $sw_version =~ /\bTHERMO_ON_AC_2\b/;
	push @flags, 'LED_ON_AC=1'      if $sw_version =~ /\bLED_ON_AC\b/;
	push @flags, 'AC_TEST=1'        if $sw_version =~ /\bAC_TEST\b/;

	# Diagnostics / Mock Output Variables
	push @flags, 'DEBUG=1'                if $sw_version =~ /\bDEBUG\b/ && $sw_version !~ /\bDEBUG_NO_METER\b/ && $sw_version !~ /\bDEBUG_STACK_TRACE\b/;
	push @flags, 'DEBUG=1 DEBUG_NO_METER=1' if $sw_version =~ /\bNO_METER\b/;
	push @flags, 'DEBUG_STACK_TRACE=1'    if $sw_version =~ /\bDEBUG_STACK_TRACE\b/;

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

		# --- TARGETED DATABASE GIT REVISION PARSER ---
		my $git_suffix = '';
		my $db_version_string = $meter->{sw_version} // '';

		# Explicit lookup for -master-[count]-[hash]- sequence anywhere inside the string
		if ($db_version_string =~ /-master-(\d+-[a-fA-F0-9]+)/) {
			$git_suffix = $1;
		}
		# General fallback if branch name changes but layout pattern holds
		elsif ($db_version_string =~ /-(?:\d+-[a-fA-F0-9]+)-/) {
			if ($db_version_string =~ /-([^-]+-[^-]+)-/) {
				$git_suffix = $1;
			}
		}

		# Disk lookup verification fallback if database parsing yields no matches
		if (!$git_suffix) {
			my $git_count = `git rev-list HEAD --count 2>/dev/null`;
			my $git_hash  = `git rev-parse --short HEAD 2>/dev/null`;
			
			if ($git_count && $git_hash) {
				chomp $git_count; chomp $git_hash;
				$git_suffix = "${git_count}-${git_hash}";
			} else {
				$git_suffix = "1462-a35f2"; 
			}
		}

		my $custom_version = "master-${git_suffix}-custom";
		if ($modifiers ne 'STANDARD') {
			$custom_version .= "-${modifiers}";
		}

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
