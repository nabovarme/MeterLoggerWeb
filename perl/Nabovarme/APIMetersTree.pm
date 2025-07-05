package Nabovarme::APIMetersTree;

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
			SELECT *
			FROM meters
			WHERE type IN ('heat', 'heat_supply', 'heat_sub')
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();

		my %nodes;			  # serial => node hashref
		my %pending_children;   # ssid => arrayref of child nodes

		while (my $row = $sth->fetchrow_hashref) {
			my $serial = $row->{serial} or next;
			my $info   = $row->{info}   || '';
			my $ssid   = $row->{ssid}   || '';

			my $node = {
				text	  => {
					name  => "$info ($serial)",
					title => $ssid,
				},
				HTMLclass => "childNode",
				children  => [],
			};

			$nodes{$serial} = $node;

			# Group nodes by their parent ssid
			push @{ $pending_children{$ssid} }, $node;
		}

		my %attached;
		my @roots;

		# Attach children nodes to their parents based on ssid references
		for my $ssid (keys %pending_children) {
			my $children = $pending_children{$ssid};

			if ($ssid =~ /^mesh-(.+)$/ && exists $nodes{$1}) {
				my $parent = $nodes{$1};
				$parent->{HTMLclass} = "rootNode";  # promote parent to root if has children
				push @{ $parent->{children} }, @$children;
				$attached{ $_ } = 1 for @$children;
			} else {
				# Synthetic root node if parent unknown
				my $synthetic = {
					text	  => { name => $ssid },
					HTMLclass => "rootNode",
					children  => $children,
				};
				push @roots, $synthetic;
				$attached{ $_ } = 1 for @$children;
			}
		}

		# Add unattached nodes as root nodes
		for my $serial (keys %nodes) {
			my $node = $nodes{$serial};
			next if $attached{$node};
			$node->{HTMLclass} = "rootNode";
			push @roots, $node;
		}

		# Sort children recursively by node name
		_sort_children_recursively($_) for @roots;

		# Build array of full Treant config objects, one per root node
		my @configs = map {
			{
				chart => {
					container       => '',  # frontend fills this dynamically
					rootOrientation => "WEST",
					nodeAlign       => "LEFT",
					connectors      => { type => "step" },
					node            => { collapsable => JSON::XS::true, HTMLclass => "nodeDefault" },
				},
				nodeStructure => $_,
			}
		} @roots;

		my $json = JSON::XS->new->utf8->canonical->encode(\@configs);
		$r->print($json);

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

sub _sort_children_recursively {
	my ($node) = @_;
	return unless $node->{children} && ref $node->{children} eq 'ARRAY';

	@{ $node->{children} } = sort {
		($a->{text}{name} // '') cmp ($b->{text}{name} // '')
	} @{ $node->{children} };

	_sort_children_recursively($_) for @{ $node->{children} };
}

1;
