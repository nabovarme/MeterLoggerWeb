#!/usr/bin/perl -w

use strict;
use warnings;
use FindBin;
use Getopt::Long qw(GetOptions);
use Curses;

use Nabovarme::OTA;
use Nabovarme::Db;

# Ensure stdout flushes immediately
$| = 1;

sub print_usage {
	print << "EOF";
Usage: $0 [options] <serial> [serial ...]

Options:
  -v, --version VERSION   Firmware version to install (default: latest)
  -c, --confirm           Query current running ROM version and confirm it
  -u, --unattended        Run without interactive prompts; confirm unconfirmed ROMs
  -R, --unattended-revert Run unattended; revert unconfirmed ROMs before updating
  -h, --help              Show this help message

Examples:
  $0 9999995
  $0 9999995 9999996 9999997
  $0 --version 20261013_152158 9999995 9999996
  $0 --confirm 9999995 9999996
  $0 --unattended 9999995 9999996
  $0 --unattended-revert 9999995 9999996
EOF
	exit 0;
}

my $help = 0;
my $confirm_only = 0;
my $unattended = 0;
my $unattended_revert = 0;
my $version = 'latest';

GetOptions(
	'help|h'              => \$help,
	'confirm|c'           => \$confirm_only,
	'unattended|u'        => \$unattended,
	'unattended-revert|R' => \$unattended_revert,
	'version|v=s'         => \$version,
) or die "Error in command line arguments\n";

print_usage() if $help;

die "Error: --unattended-revert cannot be used with --confirm.\n"
	if $confirm_only && $unattended_revert;

my @serials = @ARGV;
print_usage() if !@serials;

my @failed;
my @skipped;
my @meters;
my @log;

my $current_index = -1;
my $current_operation = 'Connecting to database...';
my $prompt_text = '';
my $prompt_input = '';
my $interrupted = 0;
my $skip_current = 0;
my $meter_operation_active = 0;
my $curses_started = 0;
my $total = scalar @serials;

my $stdscr;

for my $serial (@serials) {
	push @meters, {
		serial   => $serial,
		label    => $serial,
		status   => 'WAITING',
		detail   => '',
		progress => undef,
	};
}

# Write text using Curses window methods instead of mvaddstr().
sub put_text {
	my ($row, $col, $text) = @_;

	return if !$curses_started;

	my ($rows, $cols);
	$stdscr->getmaxyx($rows, $cols);

	return if $row < 0 || $row >= $rows;
	return if $col < 0 || $col >= $cols;

	$text = clip_text($text, $cols - $col);

	$stdscr->move($row, $col);
	$stdscr->addstr($text);
}

sub clip_text {
	my ($text, $width) = @_;

	$text //= '';
	$text =~ s/[\r\n\t]/ /g;

	return '' if $width <= 0;

	return substr($text, 0, $width);
}

# Create an ASCII progress bar compatible with limited terminal character sets.
sub progress_bar {
	my ($progress, $width) = @_;

	$width = 1 if !defined($width) || $width < 1;

	my $filled = 0;

	if (defined $progress) {
		$progress = 0 if $progress < 0;
		$progress = 100 if $progress > 100;

		$filled = int(($width * $progress / 100) + 0.5);
	}

	my $empty = $width - $filled;

	return '#' x $filled . '-' x $empty;
}

# Return combined progress across all meters.
# Finished meters count as 100%; the current meter uses reported OTA progress.
sub batch_progress {
	return 0 if !$total;

	my $sum = 0;

	for my $meter (@meters) {
		if ($meter->{status} eq 'SUCCESS'
			|| $meter->{status} eq 'FAILED'
			|| $meter->{status} eq 'SKIPPED') {
			$sum += 100;
		}
		elsif (defined $meter->{progress}) {
			$sum += $meter->{progress};
		}
	}

	return $sum / $total;
}

sub meter_progress {
	my ($meter) = @_;

	return 100 if $meter->{status} eq 'SUCCESS';
	return $meter->{progress} if defined $meter->{progress};

	return undef;
}

sub add_log {
	my ($message) = @_;

	$message //= '';
	$message =~ s/\r//g;

	push @log, split(/\n/, $message, -1);

	# Keep enough recent output for the scrolling log window.
	shift @log while @log > 1000;

	draw_dashboard() if $curses_started;
}

sub draw_dashboard {
	return if !$curses_started;

	my ($rows, $cols);
	$stdscr->getmaxyx($rows, $cols);

	$stdscr->erase();

	my $line = 0;

	put_text($line++, 0, 'MeterLogger OTA Update');

	put_text($line++, 0,
		'Firmware: ' . $version
		. ' | Mode: '
		. ($confirm_only ? 'CONFIRM'
			: $unattended_revert ? 'UNATTENDED REVERT'
			: $unattended ? 'UNATTENDED'
			: 'INTERACTIVE')
	);

	my $success_count = grep {
		$_->{status} eq 'SUCCESS'
	} @meters;

	my $failed_count = grep {
		$_->{status} eq 'FAILED'
	} @meters;

	my $skipped_count = grep {
		$_->{status} eq 'SKIPPED'
	} @meters;

	my $completed = $success_count + $failed_count + $skipped_count;
	my $remaining = $total - $completed;

	put_text($line++, 0,
		"Progress: $completed/$total completed"
		. " | Success: $success_count"
		. " | Failed: $failed_count"
		. " | Skipped: $skipped_count"
		. " | Remaining: $remaining"
	);

	# Keep the batch bar width fixed so it does not stretch across the terminal.
	my $batch_bar_width = $cols >= 50 ? 30 : 15;

	put_text($line++, 0,
		sprintf(
			'BATCH  [%s] %d/%d',
			progress_bar(batch_progress(), $batch_bar_width),
			$completed,
			$total,
		)
	);

	$line++;

	put_text($line++, 0, 'METERS');

	my $list_start = $line;
	my $reserved = 6;
	my $list_height = int(($rows - $reserved - $list_start) / 2);
	$list_height = 1 if $list_height < 1;

	my $first_meter = 0;

	if ($current_index >= $list_height) {
		$first_meter = $current_index - $list_height + 1;
	}

	for my $i ($first_meter .. $#meters) {
		last if $line >= $list_start + $list_height;
		last if $line >= $rows - $reserved;

		my $meter = $meters[$i];

		my $marker = $meter->{status} eq 'SUCCESS' ? '[OK]'
			: $meter->{status} eq 'FAILED' ? '[!!]'
			: $meter->{status} eq 'SKIPPED' ? '[--]'
			: $meter->{status} eq 'RUNNING' ? '[>>]'
			: '[..]';

		my $bar_width = $cols >= 70 ? 18
			: $cols >= 50 ? 10
			: 5;

		my $bar = progress_bar(meter_progress($meter), $bar_width);
		my $detail = $meter->{detail} // '';

		put_text($line++, 0,
			sprintf(
				'%-4s %-30s [%s] %s',
				$marker,
				$meter->{label},
				$bar,
				$detail,
			)
		);
	}

	# Reserve the bottom part of the terminal for recent output.
	my $log_header = $rows - $reserved;

	put_text($log_header, 0, 'RECENT OUTPUT');

	my $log_height = $rows - $log_header - 3;
	$log_height = 0 if $log_height < 0;

	my $log_start = @log - $log_height;
	$log_start = 0 if $log_start < 0;

	my $log_line = $log_header + 1;

	for my $i ($log_start .. $#log) {
		last if $log_line >= $rows - 2;

		put_text($log_line++, 0, $log[$i]);
	}

	if ($prompt_text ne '') {
		put_text($rows - 2, 0, $prompt_text . $prompt_input);
	} else {
		put_text($rows - 2, 0, $current_operation);
	}

	put_text($rows - 1, 0,
		'Ctrl+C: skip current meter | Second Ctrl+C: exit'
	);

	$stdscr->refresh();
}

sub prompt_line {
	my ($message, $default) = @_;

	$prompt_text = $message;
	$prompt_input = '';

	draw_dashboard();

	while (1) {
		my $key = $stdscr->getch();

		next if !defined $key;

		if ($key eq "\n" || $key eq "\r" || $key == KEY_ENTER) {
			my $answer = $prompt_input;
			$answer = $default if $answer eq '';

			$prompt_text = '';
			$prompt_input = '';

			add_log("$message$answer\n");

			return $answer;
		}

		if ($key == 27) {
			$prompt_input = '';
			draw_dashboard();
			next;
		}

		if ($key == KEY_BACKSPACE || $key == 127 || $key == 8) {
			chop $prompt_input if length $prompt_input;
			draw_dashboard();
			next;
		}

		if (length($key) == 1 && $key =~ /^[[:print:]]$/) {
			$prompt_input .= $key;
			draw_dashboard();
		}
	}
}

# Restore the terminal if the script exits unexpectedly.
END {
	if ($curses_started) {
		endwin();
	}
}

$SIG{INT} = sub {
	if ($meter_operation_active) {
		$skip_current = 1;
		die "__SKIP_CURRENT_METER__\n";
	}

	if (!$interrupted) {
		$interrupted = 1;

		add_log('WARNING: Ctrl+C received. Stopping after the current operation...');
		add_log('Press Ctrl+C again to abort immediately.');
	} else {
		endwin() if $curses_started;
		$curses_started = 0;

		print STDERR "\nAborted by user (second Ctrl+C).\n";
		exit(130);
	}
};

# Initialize curses.
$stdscr = initscr();
$curses_started = 1;

cbreak();
noecho();
keypad($stdscr, 1);

$current_operation = 'Connecting to database...';
draw_dashboard();

my $ota;
my $dbh;
my $info_sth;

eval {
	$ota = Nabovarme::OTA->new(
		logger => sub {
			my ($message) = @_;

			add_log($message);

			if (defined $message && $current_index >= 0) {
				my $meter = $meters[$current_index];

				# Track the OTA progress reported by the firmware.
				if ($message =~ /status=started\b/) {
					$meter->{progress} = 0;
					$meter->{detail} = 'OTA started';
				}
				elsif ($message =~ /status=flashing_(\d+)%/) {
					my $progress = $1;

					$progress = 100 if $progress > 100;

					$meter->{progress} = $progress;
					$meter->{detail} = 'Flashing';
				}
				elsif ($message =~ /status=success\b/) {
					$meter->{progress} = 100;
					$meter->{detail} = 'Flash complete';
				}
				elsif ($message =~ /status=restarting_in_(\d+)s/) {
					$meter->{progress} = 100;
					$meter->{detail} = 'Restarting';
				}
				elsif ($message =~ /status=self_test_passed_committed\b/) {
					$meter->{progress} = 100;
					$meter->{detail} = 'Self-test passed';
				}
				elsif ($message =~ /status=already_committed\b/) {
					$meter->{progress} = 100;
					$meter->{detail} = 'Already committed';
				}
				elsif ($message =~ /status=(error_[a-z_]+)\b/) {
					$meter->{detail} = $1;
				}
			}

			if (defined $message && $message ne '') {
				my @lines = split(/\n/, $message);
				my $last_line = $lines[-1] // '';

				$last_line =~ s/^\s+|\s+$//g;

				$current_operation = $last_line
					if $last_line ne '';
			}

			draw_dashboard();
		}
	);

	$dbh = Nabovarme::Db->my_connect
		or die "Failed to connect to database to fetch meter information\n";

	$info_sth = $dbh->prepare(qq[
		SELECT `info`
		FROM meters
		WHERE `serial` = ?
		LIMIT 1
	]);

	1;
} or do {
	my $error = $@ || "Unknown error.\n";

	add_log("ERROR: $error");

	push @failed, {
		serial => '-',
		label  => 'Database connection',
		error  => $error,
	};
};

if ($ota && $dbh && $info_sth) {
	# Fetch info for every requested meter before starting OTA processing.
	# This lets the dashboard show all meter labels while they are waiting.
	for my $i (0 .. $#serials) {
		my $serial = $serials[$i];
		my $meter = $meters[$i];
		my $info;

		eval {
			$info_sth->execute($serial);
			($info) = $info_sth->fetchrow_array;
			$info_sth->finish;

			1;
		} or do {
			my $error = $@ || "Failed to fetch meter information.\n";

			$meter->{info_error} = $error;
			add_log("ERROR: Failed to fetch info for meter $serial: $error");
		};

		$meter->{label} = $serial;
		$meter->{label} .= " - $info" if defined $info && $info ne '';
	}

	draw_dashboard();

	for my $i (0 .. $#serials) {
		last if $interrupted;

		$current_index = $i;

		my $serial = $serials[$i];
		my $meter = $meters[$i];
		my $meter_label = $meter->{label};

		$meter->{status} = 'RUNNING';
		$meter->{detail} = '';
		$meter->{progress} = undef;

		$current_operation = "Preparing meter $serial...";
		draw_dashboard();

		if (defined $meter->{info_error}) {
			my $error = $meter->{info_error};

			$meter->{status} = 'FAILED';
			$meter->{detail} = 'Database error';

			push @failed, {
				serial => $serial,
				label  => $meter_label,
				error  => $error,
			};

			add_log("ERROR: Meter $serial: $error");
			next;
		}

		my $ok;
		my $error;

		$skip_current = 0;
		$meter_operation_active = 1;

		eval {
			if ($confirm_only) {
				$ok = $ota->confirm(
					$serial,
					unattended => $unattended,
					on_prompt  => sub {
						return prompt_line(
							'Confirm running ROM permanently? [y/N]: ',
							'n'
						);
					}
				);
			} else {
				$ok = $ota->update(
					$serial,
					version           => $version,
					unattended        => ($unattended || $unattended_revert),
					unattended_revert => $unattended_revert,
					on_unconfirmed    => sub {
						add_log(
							"Unconfirmed ROM detected. Choose an action:\n"
							. "  C - Confirm the running ROM and retry OTA (default)\n"
							. "  R - Restart and revert to the previous ROM\n"
							. "  A - Abort\n"
						);

						return prompt_line(
							'Choose action [C/r/a]: ',
							'c'
						);
					}
				);
			}

			1;
		} or do {
			$error = $@ || "Unknown error.\n";
		};

		$meter_operation_active = 0;

		if ($skip_current) {
			$meter->{status} = 'SKIPPED';
			$meter->{detail} = 'Skipped by user';

			push @skipped, $meter_label;
			add_log("Meter $meter_label skipped by user (Ctrl+C).");
		}
		elsif (defined($error) && $error ne '') {
			$meter->{status} = 'FAILED';
			$meter->{detail} = 'Operation failed';

			add_log("ERROR: Meter $meter_label failed: $error");

			push @failed, {
				serial => $serial,
				label  => $meter_label,
				error  => $error,
			};
		}
		elsif (!$ok) {
			$meter->{status} = 'SKIPPED';
			$meter->{detail} = 'Skipped';

			push @skipped, $meter_label;
			add_log("Meter $meter_label skipped.");
		}
		else {
			$meter->{status} = 'SUCCESS';
			$meter->{detail} = 'Completed';
			$meter->{progress} = 100;

			add_log("Meter $meter_label completed successfully.");
		}

		$current_operation = "Completed meter $meter_label";
		draw_dashboard();
	}

	$dbh->disconnect();
}

add_log('');
add_log('=' x 60);

add_log(
	'Batch processing completed'
	. ($interrupted ? ' (interrupted by user)' : '')
	. '.'
);

if (@failed) {
	add_log('');
	add_log('Failed ' . ($confirm_only ? 'confirmations' : 'upgrades') . ':');

	for my $failure (@failed) {
		my $error = $failure->{error};
		$error =~ s/\s+\z//;

		add_log("  Meter $failure->{label}: $error");
	}
} else {
	add_log(
		'No '
		. ($confirm_only ? 'confirmation failures' : 'upgrade failures')
		. '.'
	);
}

add_log("Skipped meters: " . join(", ", @skipped)) if @skipped;

add_log('Batch interrupted; remaining meters were not processed.')
	if $interrupted;

$current_operation = 'Press any key to exit.';
draw_dashboard();

$stdscr->getch();

endwin();
$curses_started = 0;

exit($interrupted ? 130 : @failed ? 1 : 0);
