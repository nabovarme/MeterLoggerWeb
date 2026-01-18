#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);
use Curses;
use Email::MIME;
use Encode qw(decode is_utf8);
use Time::HiRes qw(time);

# -----------------------------
# Subroutine to get queue list
# -----------------------------
sub get_queue_list {
	my @list;
	open my $pq, "-|", "/usr/sbin/postqueue -p" or return @list;
	while (<$pq>) {
		if (/^([A-F0-9]+)\*?\s+(\S+)\s+/) {
			push @list, {
				id      => $1,
				from    => $2,
				subject => '',
				to      => '',
				date    => '',
			};
		}
	}
	close $pq;
	return @list;
}

# -----------------------------
# Load headers for all messages
# -----------------------------
sub load_all_headers {
	my ($queue_ref) = @_;
	for my $msg (@$queue_ref) {
		open my $pc, "-|", "/usr/sbin/postcat -q $msg->{id}" or next;
		my $raw = do { local $/; <$pc> };
		close $pc;

		my $email = eval { Email::MIME->new($raw) };
		next unless $email;

		$msg->{subject} = $email->header_str("Subject") // "";
		$msg->{to}      = $email->header_str("To")      // "";
		$msg->{date}    = $email->header("Date")        // "";
	}
}

# -----------------------------
# Sorting state
# -----------------------------
my $sort_mode  = 'time';  # 'time', 'subject', or 'to'
my $sort_order = 1;       # 1 = ascending, -1 = descending

# -----------------------------
# Initial queue load and sort
# -----------------------------
my @queue = get_queue_list();
load_all_headers(\@queue);

if ($sort_mode eq 'subject') {
	@queue = sort { $sort_order * (lc($a->{subject}) cmp lc($b->{subject})) } @queue;
}
elsif ($sort_mode eq 'time') {
	@queue = sort { $sort_order * ($a->{date} cmp $b->{date}) } @queue;
}
elsif ($sort_mode eq 'to') {
	@queue = sort {
		my ($ato) = $a->{to} =~ /^(.*?)@/;
		my ($bto) = $b->{to} =~ /^(.*?)@/;
		$ato ||= '';
		$bto ||= '';
		$sort_order * (lc($ato) cmp lc($bto))
	} @queue;
}

# Select first row after sort
my $sel = 0;

# Scroll first row to top
my $scroll = 0;

# -----------------------------
# Initialize Curses
# -----------------------------
initscr();
noecho();
cbreak();
keypad(stdscr, 1);
my $header_lines = 2;
my $max_y = getmaxy(stdscr) - $header_lines;
my $last_refresh = time();
timeout(500);  # non-blocking getch

# -----------------------------
# Main loop
# -----------------------------
while (1) {

	# -----------------------------
	# Auto-refresh every 10 seconds
	# -----------------------------
	if (time() - $last_refresh >= 10) {
		my $sel_id = $queue[$sel]{id} if $sel <= $#queue;

		@queue = get_queue_list();
		load_all_headers(\@queue);

		# Restore selection
		if ($sel_id) {
			my $found = 0;
			for my $i (0..$#queue) {
				if ($queue[$i]{id} eq $sel_id) {
					$sel = $i;
					$found = 1;
					last;
				}
			}
			$sel = 0 unless $found;
		}

		# Keep scroll sane
		$scroll = $sel if $scroll > $sel;

		$last_refresh = time();
	}

	# -----------------------------
	# Sort queue
	# -----------------------------
	my $sel_id = $queue[$sel]{id} if $sel <= $#queue;

	if ($sort_mode eq 'subject') {
		@queue = sort { $sort_order * (lc($a->{subject}) cmp lc($b->{subject})) } @queue;
	}
	elsif ($sort_mode eq 'time') {
		@queue = sort { $sort_order * ($a->{date} cmp $b->{date}) } @queue;
	}
	elsif ($sort_mode eq 'to') {
		@queue = sort {
			my ($ato) = $a->{to} =~ /^(.*?)@/;
			my ($bto) = $b->{to} =~ /^(.*?)@/;
			$ato ||= '';
			$bto ||= '';
			$sort_order * (lc($ato) cmp lc($bto))
		} @queue;
	}

	# Restore selection after sort
	if ($sel_id) {
		for my $i (0..$#queue) {
			if ($queue[$i]{id} eq $sel_id) {
				$sel = $i;
				last;
			}
		}
	}

	# -----------------------------
	# Draw UI
	# -----------------------------
	clear();
	my $win_width = getmaxx(stdscr);

	printw("Postfix Queue Viewer (Arrow keys: navigate, d: delete, q: quit, t: sort time, s: sort subject, o: sort to)\n");
	printw("-" x $win_width . "\n");

	my $end = $scroll + $max_y - 1;
	$end = $#queue if $end > $#queue;

	for my $i ($scroll .. $end) {
		my $msg = $queue[$i];
		my $to_short = $msg->{to} =~ /^(.*?)@/ ? $1 : $msg->{to};

		move($i - $scroll + $header_lines, 0);

		# Calculate column widths
		my $id_w      = 8;
		my $date_w    = 25;
		my $to_w      = 25;
		my $subject_w = $win_width - ($id_w + $date_w + $to_w + 4);  # 4 spaces for gaps

		my $line = sprintf "%-*.*s %-*.*s %-*.*s %-*.*s",
			$id_w, $id_w, $msg->{id},
			$date_w, $date_w, $msg->{date},
			$to_w, $to_w, $to_short,
			$subject_w, $subject_w, $msg->{subject};

		if ($i == $sel) {
			attron(A_REVERSE);
			printw($line);
			attroff(A_REVERSE);
		} else {
			printw($line);
		}
	}
	refresh();

	# -----------------------------
	# Handle input
	# -----------------------------
	my $ch = getch();
	if (defined $ch) {
		if ($ch eq 'q') { last; }

		elsif ($ch eq 'd') {
			my $qid = $queue[$sel]{id};
			my $ret = system("/usr/sbin/postsuper -d $qid");
			if ($ret == 0) {
				splice(@queue, $sel, 1);

				# Adjust selection if last row was deleted
				$sel-- if $sel > $#queue;

				# Adjust scroll only if selection goes out of view
				$scroll-- if $sel < $scroll;
				$scroll++ if $sel > $scroll + $max_y - 1;

				# Ensure scroll is not negative
				$scroll = 0 if $scroll < 0;
			} else {
				move($max_y + 3, 0);
				printw("Failed to delete mail $qid. Ensure sudo/root privileges.");
				getch();
			}
		}

		elsif ($ch eq Curses::KEY_DOWN) {
			$sel++ if $sel < $#queue;
			$scroll++ if $sel > $scroll + $max_y - 1;
		}
		elsif ($ch eq Curses::KEY_UP) {
			$sel-- if $sel > 0;
			$scroll-- if $sel < $scroll;
		}

		elsif ($ch eq 't') {
			if ($sort_mode eq 'time') { $sort_order *= -1; }
			else { $sort_mode = 'time'; $sort_order = 1; }
		}
		elsif ($ch eq 's') {
			if ($sort_mode eq 'subject') { $sort_order *= -1; }
			else { $sort_mode = 'subject'; $sort_order = 1; }
		}
		elsif ($ch eq 'o') {
			if ($sort_mode eq 'to') { $sort_order *= -1; }
			else { $sort_mode = 'to'; $sort_order = 1; }
		}
	}
}

# -----------------------------
# Cleanup
# -----------------------------
endwin();
