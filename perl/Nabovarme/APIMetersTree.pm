package Nabovarme::APIMetersTree;

use strict;
use warnings;
use utf8;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::Const -compile => qw(OK HTTP_SERVICE_UNAVAILABLE);
use HTTP::Date;
use JSON::XS;

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
			SELECT serial, info, ssid
			FROM meters
			WHERE type IN ('heat', 'heat_supply', 'heat_sub')
		];

		$sth = $dbh->prepare($sql);
		$sth->execute();

		my %nodes;               # serial => node
		my %mesh_id_to_serial;   # mesh-serial => serial
		my %pending_children;    # ssid => [ node, node, ... ]

		# First pass: create node objects for each meter
		while (my $row = $sth->fetchrow_hashref) {
			my $serial = $row->{serial} or next;
			my $info   = $row->{info}   || '';
			my $ssid   = $row->{ssid}   || '';

			my $node = {
				text      => { name => "$info ($serial)" },
				HTMLclass => "childNode",  # default class for meters
				children  => [],
				_serial   => $serial,       # temp for sorting
			};

			$nodes{$serial} = $node;
			$mesh_id_to_serial{"mesh-$serial"} = $serial;

			push @{ $pending_children{$ssid} }, $node;
		}

		my %attached; # serials already assigned as children
		my @roots;    # root nodes (real or synthetic)

		# Second pass: assign children to parents or synthetic nodes
		for my $ssid (keys %pending_children) {
			my $children = $pending_children{$ssid};

			if ($ssid =~ /^mesh-(\d+)$/ && exists $nodes{$1}) {
				# ssid matches an existing meter’s serial, so children are its children
				my $parent = $nodes{$1};
				$parent->{HTMLclass} = "rootNode";  # parent nodes are rootNode class
				push @{ $parent->{children} }, @$children;
				$attached{$_->{_serial}} = 1 for @$children;
			}
			else {
				# ssid does NOT match any serial — create synthetic parent node
				my $synthetic = {
					text      => { name => $ssid },
					HTMLclass => "rootNode", # synthetic parent is rootNode
					children  => $children,
				};
				push @roots, $synthetic;
				$attached{$_->{_serial}} = 1 for @$children;
			}
		}

		# Add any unassigned nodes as root nodes
		for my $serial (keys %nodes) {
			next if $attached{$serial};
			my $node = $nodes{$serial};
			$node->{HTMLclass} = "rootNode";
			push @roots, $node;
		}

		# Recursively sort all children alphabetically by text name
		_sort_children_recursively($_) for @roots;

		# If multiple roots, wrap them under a single root node for Treant
		my $tree = {
			chart => {
				container       => "#OrganiseChart-simple",
				rootOrientation => "NORTH",
				node            => { HTMLclass => "childNode" },
				connectors      => { type => "step" },
			},
			nodeStructure => @roots > 1
				? {
					text      => { name => "Root" },
					HTMLclass => "rootNode",
					children  => \@roots,
				}
				: $roots[0],
		};

		my $json = JSON::XS->new->utf8->canonical->encode($tree);
		$r->print($json);

		return Apache2::Const::OK;
	}

	$r->err_headers_out->set('Retry-After' => '60');
	return Apache2::Const::HTTP_SERVICE_UNAVAILABLE;
}

# Recursively sort children nodes by their label alphabetically
sub _sort_children_recursively {
	my ($node) = @_;
	return unless $node->{children} && ref $node->{children} eq 'ARRAY';

	@{ $node->{children} } = sort {
		($a->{text}{name} // '') cmp ($b->{text}{name} // '')
	} @{ $node->{children} };

	_sort_children_recursively($_) for @{ $node->{children} };
}

1;
