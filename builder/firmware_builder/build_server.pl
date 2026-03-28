#!/usr/bin/perl -w

use strict;
use warnings;

use Mojolicious::Lite;
use JSON;

use lib qw( ./perl );
use Nabovarme::Db;
use File::Copy qw(move);

use constant BUILD_COMMAND => 'make clean all';
use constant REPO_DIR => '/meterlogger/MeterLogger';
use constant RELEASE_DIR => '/meterlogger/MeterLogger/release';
use constant FIRMWARE => '/meterlogger/MeterLogger/release/firmware.bin';

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
	# Update repo ONCE before all builds
	my $repo_dir = REPO_DIR;
	if (-d $repo_dir) {
		print "Updating repository...\n";
		my $git_output = `cd $repo_dir && git pull 2>&1`;
		print "Git output: $git_output\n";
	}
	else {
		warn "Repo directory not found: $repo_dir\n";
	}

	my $sth = $dbh->prepare("SELECT serial FROM meters WHERE enabled = 1");
	$sth->execute;

	my @results;

	while (my ($serial) = $sth->fetchrow_array) {
		print "Building serial: $serial\n";
		my $res = run_build($serial);

		push @results, {
			serial => $serial,
			%$res
		};
	}

	return \@results;
}

sub run_build {
	my ($meter_serial) = @_;

	my $dbh;
	if ($dbh = Nabovarme::Db->my_connect) {
		$dbh->{'mysql_auto_reconnect'} = 1;
	}

	my $sth = $dbh->prepare(
		"SELECT `key`, `sw_version` FROM meters WHERE serial = " . $dbh->quote($meter_serial) . " LIMIT 1"
	);

	$sth->execute;

	if ($sth->rows) {
		my $row = $sth->fetchrow_hashref;

		my $key = $row->{key} || warn "no aes key found\n";
		my $sw_version = $row->{sw_version} || warn "no sw_version found\n";

		my $DEFAULT_BUILD_VARS = 'AP=1';

		if ($sw_version =~ /NO_AUTO_CLOSE/) {
			$DEFAULT_BUILD_VARS .= ' AUTO_CLOSE=0';
		}

		if ($sw_version =~ /NO_CRON/) {
			$DEFAULT_BUILD_VARS .= ' NO_CRON=1';
		}

		if ($sw_version =~ /DEBUG_STACK_TRACE/) {
			$DEFAULT_BUILD_VARS .= ' DEBUG_STACK_TRACE=1';
		}

		if ($sw_version =~ /THERMO_ON_AC_2/) {
			$DEFAULT_BUILD_VARS .= ' THERMO_ON_AC_2=1';
		}

		my $cmd;

		if ($sw_version =~ /MC-B/) {
			$cmd = BUILD_COMMAND . " $DEFAULT_BUILD_VARS MC_66B=1 SERIAL=$meter_serial KEY=$key";
		}
		elsif ($sw_version =~ /MC/) {
			$cmd = BUILD_COMMAND . " $DEFAULT_BUILD_VARS EN61107=1 SERIAL=$meter_serial KEY=$key";
		}
		elsif ($sw_version =~ /NO_METER/) {
			$cmd = BUILD_COMMAND . " $DEFAULT_BUILD_VARS DEBUG=1 DEBUG_NO_METER=1 SERIAL=$meter_serial KEY=$key";
		}
		else {
			$cmd = BUILD_COMMAND . " $DEFAULT_BUILD_VARS SERIAL=$meter_serial KEY=$key";
		}

		print "Running: $cmd\n";

		my $repo_dir = REPO_DIR;
		my $output = `cd $repo_dir && $cmd 2>&1`;
		my $exit_code = $? >> 8;

		my $success = ($exit_code == 0);

		if ($success) {
			my $src = FIRMWARE;
			my $dst = RELEASE_DIR . "/$meter_serial.bin";

			if (-e $src) {
				if (move($src, $dst)) {
					print "Moved firmware to $dst\n";
				}
				else {
					warn "Failed to move firmware: $!";
					$success = 0;
				}
			}
			else {
				warn "Firmware file not found: $src";
				$success = 0;
			}
		}

		return {
			success => $success ? 1 : 0,
			exit_code => $exit_code,
			command => $cmd,
			output => $output
		};
	}

	return {
		success => 0,
		error => "Meter not found"
	};
}

app->start;
