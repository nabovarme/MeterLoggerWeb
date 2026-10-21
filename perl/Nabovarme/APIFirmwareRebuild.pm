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
use Nabovarme::FirmwareBuilder qw(build_flags_from_sw_version);

sub handler {
	my $r = shift;
	my ($dbh,$sth);

	if ($dbh = Nabovarme::Db->my_connect) {$r->content_type("application/json; charset=utf-8");
		$r->headers_out->set('Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0');$r->headers_out->set('Pragma' => 'no-cache');
		$r->headers_out->set('Expires' => '0');$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		if ($r->method ne 'POST') {$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Method not allowed" }));
			return Apache2::Const::OK;
		}

		my %params;
		my $args_string = $r->args || '';
		foreach my $pair (split(/[&;]/,$args_string)) {
			my ($key, $val) = split(/=/,$pair, 2);
			next unless defined $key;
			$val = '' unless defined$val;
			$key =~ tr/+/ /;$key =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
			$val =~ tr/+/ /;$val =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
			$params{$key} = $val;
		}

		my $serial    = $params{serial};
		my $modifiers = $params{sw_version_modifiers} || 'STANDARD';

		if (!defined $serial || $serial eq '') {$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Missing target serial identity parameter context" }));
			return Apache2::Const::OK;
		}

		my $sql = q[SELECT info, sw_version FROM meters WHERE serial = ? AND enabled = 1 LIMIT 1];
		$sth = $dbh->prepare($sql);
		$sth->execute($serial);
		my $meter = $sth->fetchrow_hashref;

		if (!$meter) {$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Active targeted meter context not found" }));
			return Apache2::Const::OK;
		}

		# --- TARGETED DATABASE GIT REVISION & BRANCH PARSER ---
		my $git_branch = 'master';
		my $git_suffix = '';
		my $db_version_string = $meter->{sw_version} // '';

		# Match standard full branch layouts: [branch]-[count]-[hash]
		if ($db_version_string =~ /^([a-zA-Z0-9._-]+)-(\d+-[a-f0-9]+)/) {$git_branch = $1;
			$git_suffix = $2;
			
			if ($git_branch =~ /^(.*)-custom$/) {$git_branch = $1;
			}
		}
		# Fallback tracking for legacy -master-[count]-[hash]- structures anywhere inside the string
		elsif ($db_version_string =~ /-(master)-(\d+-[a-f0-9]+)/) {$git_branch = $1;
			$git_suffix = $2;
		}

		# Disk lookup verification fallback if database parsing yields no matches
		if (!$git_suffix) {
			my $git_cnt = `git rev-list HEAD --count 2>/dev/null`;
			my $git_hsh = `git rev-parse --short HEAD 2>/dev/null`;
			my $git_brn = `git rev-parse --abbrev-ref HEAD 2>/dev/null`;
			
			if ($git_cnt && $git_hsh) {
				chomp $git_cnt; chomp$git_hsh;
				$git_suffix = "${git_cnt}-${git_hsh}";
				
				if ($git_brn) {
					chomp $git_brn;
					$git_branch = $git_brn if$git_brn ne 'HEAD';
				}
			} else {
				if ($db_version_string =~ /^([a-zA-Z0-9._-]+?)(?:-custom)?$/) {
					my @parts = split(/-/, $1);
					if (@parts >= 3) {
						$git_suffix = pop(@parts);
						$git_suffix = pop(@parts) . "-" . $git_suffix;
						$git_branch = join("-", @parts);
					} else {
						$git_branch = $db_version_string || 'master';
						$git_suffix = 'build-error';
					}
				} else {
					$git_branch = 'master';$git_suffix = 'unknown';
				}
			}
		}

		# Ensure the version variable string layout maintains the exact naming target written to storage paths
		my $custom_version = "${git_branch}-${git_suffix}-CUSTOM";
		if ($modifiers ne 'STANDARD') {
			$custom_version .= "-${modifiers}";
		}

		my $redis;
		eval {
			$redis = Redis->new(server => "$ENV{REDIS_HOST}:$ENV{REDIS_PORT}");
		};
		if ($@) {$r->print(JSON->new->utf8->canonical->encode({ success => 0, error => "Redis message broker engine connectivity failure" }));
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
