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

	# Extract out the bracketed segment metadata if present, otherwise read full string tokens
	my $flags_segment = $sw_version;
	if ($sw_version =~ /\[(.*?)\]/) {
		$flags_segment = $1;
	}

	# Split on spaces to isolate specific tokens like "FLOW_METER=1" or "NO_CRON=1"
	my @tokens = split(/\s+/, $flags_segment);

	# Helper function to extract explicit key/value bindings
	my $check_flag = sub {
		my ($flag_name, $default_on_match) = @_;
		$default_on_match //= 1;

		# Find explicit token matching "FLAG_NAME=" key pairs
		my ($matched_token) = grep { $_ =~ /^$flag_name=/ } @tokens;
		if ($matched_token) {
			my (undef, $val) = split(/=/, $matched_token, 2);
			return $val eq '1' ? 1 : 0;
		}

		# Fallback to bare keyword check if present without explicit values
		if (grep { $_ eq $flag_name } @tokens) {
			return $default_on_match;
		}

		return undef;
	};

	my @flags = ('AP=1');

	# 1. Core Hardware Protocol Auto-Selectors
	if (($check_flag->('MC_66B') // 0) == 1) {
		push @flags, 'MC_66B=1';
	}
	elsif (($check_flag->('EN61107') // 0) == 1) {
		push @flags, 'EN61107=1';
	}
	elsif (($check_flag->('IMPULSE') // 0) == 1) {
		push @flags, 'IMPULSE=1';
	}

	# 2. Logic Overrides & Modifiers
	my $flow_meter = $check_flag->('FLOW_METER');
	push @flags, "FLOW_METER=1" if defined $flow_meter && $flow_meter == 1;

	# Note: NO_AUTO_CLOSE=1 maps internally to AUTO_CLOSE=0
	my $no_auto_close = $check_flag->('NO_AUTO_CLOSE');
	my $auto_close    = $check_flag->('AUTO_CLOSE');
	if ((defined $no_auto_close && $no_auto_close == 1) || (defined $auto_close && $auto_close == 0)) {
		push @flags, 'AUTO_CLOSE=0';
	}

	my $no_cron = $check_flag->('NO_CRON');
	push @flags, "NO_CRON=1" if defined $no_cron && $no_cron == 1;

	# 3. Actuator Configuration States
	my $thermo_no = $check_flag->('THERMO_NO');
	my $thermo_nc = $check_flag->('THERMO_NC');
	if ((defined $thermo_no && $thermo_no == 1) || (defined $thermo_nc && $thermo_nc == 0)) {
		push @flags, 'THERMO_NO=1';
	}
	elsif ((defined $thermo_nc && $thermo_nc == 1) || (defined $thermo_no && $thermo_no == 0)) {
		push @flags, 'THERMO_NO=0';
	}

	my $thermo_ac2 = $check_flag->('THERMO_ON_AC_2');
	push @flags, "THERMO_ON_AC_2=1" if defined $thermo_ac2 && $thermo_ac2 == 1;

	my $led_on_ac = $check_flag->('LED_ON_AC');
	push @flags, "LED_ON_AC=1" if defined $led_on_ac && $led_on_ac == 1;

	my $ac_test = $check_flag->('AC_TEST');
	push @flags, "AC_TEST=1" if defined $ac_test && $ac_test == 1;

	# 4. Diagnostics & Trace Variables
	my $debug          = $check_flag->('DEBUG');
	my $debug_no_meter = $check_flag->('DEBUG_NO_METER') // $check_flag->('NO_METER');
	my $stack_trace    = $check_flag->('DEBUG_STACK_TRACE');

	if ((defined $debug_no_meter && $debug_no_meter == 1)) {
		push @flags, 'DEBUG=1 DEBUG_NO_METER=1';
	}
	elsif ((defined $debug && $debug == 1)) {
		push @flags, 'DEBUG=1';
	}

	push @flags, "DEBUG_STACK_TRACE=1" if defined $stack_trace && $stack_trace == 1;

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

		# --- TARGETED DATABASE GIT REVISION & BRANCH PARSER ---
		my $git_branch = 'master';
		my $git_suffix = '';
		my $db_version_string = $meter->{sw_version} // '';

		# Match standard full branch layouts: [branch]-[count]-[hash]
		if ($db_version_string =~ /^([a-zA-Z0-9._-]+)-(\d+-[a-fA-F0-9]+)/) {
			$git_branch = $1;
			$git_suffix = $2;
			
			if ($git_branch =~ /^(.*)-custom$/) {
				$git_branch = $1;
			}
		}
		# Fallback tracking for legacy -master-[count]-[hash]- structures anywhere inside the string
		elsif ($db_version_string =~ /-(master)-(\d+-[a-fA-F0-9]+)/) {
			$git_branch = $1;
			$git_suffix = $2;
		}

		# Disk lookup verification fallback if database parsing yields no matches
		if (!$git_suffix) {
			my $git_cnt = `git rev-list HEAD --count 2>/dev/null`;
			my $git_hsh = `git rev-parse --short HEAD 2>/dev/null`;
			my $git_brn = `git rev-parse --abbrev-ref HEAD 2>/dev/null`;
			
			if ($git_cnt && $git_hsh) {
				chomp $git_cnt; chomp $git_hsh;
				$git_suffix = "${git_cnt}-${git_hsh}";
				
				if ($git_brn) {
					chomp $git_brn;
					$git_branch = $git_brn if $git_brn ne 'HEAD';
				}
			} else {
				$git_branch = "master";
				$git_suffix = "1462-a35f2"; 
			}
		}

		# Assemble the version key cleanly matching your strict uppercase dash layout rule
		my $custom_version = "${git_branch}-${git_suffix}-CUSTOM";
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
