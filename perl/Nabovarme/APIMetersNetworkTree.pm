package Nabovarme::APIMetersNetworkTree;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use HTTP::Date;
use JSON::XS ();

use lib qw(/etc/apache2/perl);
use Nabovarme::Db;

sub handler {
	my $r = shift;
	my ($dbh, $sth);

	if ($dbh = Nabovarme::Db->my_connect) {
		$r->content_type("application/json; charset=utf-8");
		$r->headers_out->set('Cache-Control' => 'max-age=60, public');
		$r->headers_out->set('Expires' => HTTP::Date::time2str(time + 60));
		$r->err_headers_out->add("Access-Control-Allow-Origin" => '*');

		my $sql = q[
			SELECT
				mg.`group` AS meter_group,
				mg.`id` AS group_id,
				m.*,
				latest_sc.energy,
				latest_sc.volume,
				latest_sc.hours,
				ROUND(
					IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value,
					2
				) AS kwh_remaining,
				ROUND(
					IF(latest_sc.effect > 0,
						(IFNULL(paid_kwh_table.paid_kwh, 0) - IFNULL(latest_sc.energy, 0) + m.setup_value) / latest_sc.effect,
						NULL
					),
					2
				) AS time_left_hours,
				latest_sc.unix_time AS last_sample_time
			FROM meters m
			JOIN meter_groups mg ON m.`group` = mg.`id`
			LEFT JOIN (
				SELECT sc1.*
				FROM samples_cache sc1
				INNER JOIN (
					SELECT serial, MAX(unix_time) AS max_time
					FROM samples_cache
					GROUP BY serial
				) latest ON sc1.serial = latest.serial AND sc1.unix_time = latest.max_time
			) latest_sc ON m.serial = latest_sc.serial
			LEFT JOIN (
				SELECT serial, SUM(amount / price) AS paid_kwh
				FROM accounts
				GROUP BY serial
			) paid_kwh_table ON m.serial = paid_kwh_table.serial
			WHERE m.type IN ('heat', 'heat_supply', 'heat_sub')
			ORDER BY mg.`id`, m.info
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();

		my %nodes;            # serial => node hashref
		my %pending_children; # ssid => arrayref of child nodes

		while (my $row = $sth->fetchrow_hashref) {
			my $serial = $row->{serial} or next;
			my $ssid   = $row->{ssid}   || '';

			# meter contains the whole row hashref as-is
			my $node = {
				meter   => $row,
				clients => [],
			};

			$nodes{$serial} = $node;
			push @{ $pending_children{$ssid} }, $node;
		}

		my %attached;
		my @roots;

		for my $ssid (keys %pending_children) {
			my $children = $pending_children{$ssid};

			if ($ssid =~ /^mesh-(.+)$/ && exists $nodes{$1}) {
				my $parent = $nodes{$1};
				push @{ $parent->{clients} }, @$children;
				$attached{ $_ } = 1 for @$children;
			}
			else {
				push @roots, {
					router  => { name => $ssid },
					clients => $children,
				};
				$attached{ $_ } = 1 for @$children;
			}
		}

		for my $serial (keys %nodes) {
			my $node = $nodes{$serial};
			next if $attached{$node};
			push @roots, $node;
		}

		_sort_clients_recursively($_) for @roots;

		my $json = JSON::XS->new->utf8->canonical->encode(\@roots);
		$r->print($json);

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

sub _sort_clients_recursively {
	my ($node) = @_;
	return unless $node->{clients} && ref $node->{clients} eq 'ARRAY';

	@{ $node->{clients} } = sort {
		( ($a->{meter}{info} || $a->{router}{name} || '') cmp
		  ($b->{meter}{info} || $b->{router}{name} || '') )
	} @{ $node->{clients} };

	_sort_clients_recursively($_) for @{ $node->{clients} };
}

1;
