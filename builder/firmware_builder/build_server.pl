#!/usr/bin/perl -w

use strict;
use warnings;

use Mojolicious::Lite;
use JSON;

use lib qw( /usr/local/share/perl );
use Nabovarme::Db;

use Parallel::ForkManager;

use constant DOCKER_IMAGE => 'firmware_sdk:latest';
use constant RELEASE_DIR => '/meterlogger/MeterLogger/release';

post '/build' => sub {
	my $c = shift;

	my $data = $c->req->json;

	unless ($data && $data->{serial}) {
		return $c->render(json => { error => "Missing serial" }, status => 400);
	}

	my $result = run_build($data->{serial});

	$c->render(json => $result);
};

post '/build-all' => sub {
	my $c = shift;

	my $dbh = Nabovarme::Db->my_connect;

	unless ($dbh) {
		return $c->render(json => { error => "DB connection failed" }, status => 500);
	}

	$dbh->{'mysql_auto_reconnect'} = 1;

	my $result = run_build_all($dbh);

	$c->render(json => {
		success => 1,
		results => $result
	});
};

sub run_build_all {
	my ($dbh) = @_;

	my $sth = $dbh->prepare("
		SELECT serial, `key`, sw_version
		FROM meters
		WHERE enabled = 1
	");

	$sth->execute;

	my @results;

	# Limit parallel builds (adjust as needed)
	my $pm = Parallel::ForkManager->new(10);

	while (my $row = $sth->fetchrow_hashref) {

		$pm->start and next;

		my $serial = $row->{serial};
		my $key = $row->{key};
		my $sw_version = $row->{sw_version};

		print "Building serial: $serial\n";

		my $res = run_docker_build($serial, $key, $sw_version);
		push @results, $res;

		$pm->finish(0, $res);
	}

	$pm->wait_all_children;

	return \@results;
}

sub run_build {
	my ($serial) = @_;

	my $dbh = Nabovarme::Db->my_connect;

	return { success => 0, error => "DB connection failed" } unless $dbh;

	my $sth = $dbh->prepare(
		"SELECT `key`, sw_version FROM meters WHERE serial = " . $dbh->quote($serial) . " LIMIT 1"
	);

	$sth->execute;

	if (my $row = $sth->fetchrow_hashref) {

		return run_docker_build($serial, $row->{key}, $row->{sw_version});
	}

	return { success => 0, error => "Meter not found" };
}

sub run_docker_build {
	my ($serial, $key, $sw_version) = @_;

	my @build_flags = ('AP=1');

	if ($sw_version =~ /NO_AUTO_CLOSE/) {
		push @build_flags, 'AUTO_CLOSE=0';
	}

	if ($sw_version =~ /NO_CRON/) {
		push @build_flags, 'NO_CRON=1';
	}

	if ($sw_version =~ /DEBUG_STACK_TRACE/) {
		push @build_flags, 'DEBUG_STACK_TRACE=1';
	}

	if ($sw_version =~ /THERMO_ON_AC_2/) {
		push @build_flags, 'THERMO_ON_AC_2=1';
	}

	my $extra_flags = join(' ', @build_flags);

	my $docker_cmd = join(" ",
		"docker run --rm",
		"-e SERIAL=$serial",
		"-e KEY=$key",
		"-e BUILD_FLAGS=\"$extra_flags\"",
		"-v firmware_release:" . RELEASE_DIR,
		DOCKER_IMAGE
	);
	
	print "Running: $docker_cmd\n";

	my $output = `$docker_cmd 2>&1`;
	my $exit_code = $? >> 8;

	my $success = ($exit_code == 0);

	if (!$success) {
		warn "Build failed for $serial\n$output\n";
	}

	return {
		serial => $serial,
		success => $success ? 1 : 0,
		exit_code => $exit_code,
		output => $output
	};
}

app->start;
