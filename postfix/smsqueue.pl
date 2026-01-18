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
				loaded  => 0,
				subject => '',
				to      => '',
				date    => '',
			};
		}
	}
	close $pq;
	return @list;
}

my @queue = get_queue_list();

# -----------------------------
# Initialize Curses
# -----------------------------
initscr();
noecho();
cbreak();
keypad(stdscr, 1);
my $sel = 0;
my $scroll = 0;
my $max_y = getmaxy(stdscr) - 2;
my $last_refresh = time();
timeout(500);	# non-blocking getch for auto-refresh

# -----------------------------
# Sorting state
# -----------------------------
my $sort_mode  = 'time';  # 'time' or 'subject'
my $sort_order = 1;       # 1 = ascending, -1 = descending

# -----------------------------
# Lazy-load headers
# -----------------------------
sub load_headers {
	my ($msg) = @_;
	return if $msg->{loaded};

	open my $pc, "-|", "/usr/sbin/postcat -q $msg->{id}" or return;
	my $raw = do { local $/; <$pc> };
	close $pc;

	my $email = eval { Email::MIME->new($raw) };
	if ($email) {
		# header_str returns UTF-8 flagged string
		$msg->{subject} = $email->header_str("Subject") // "";

		# To and Date
		$msg->{to}      = $email->header_str("To") // "";
		$msg->{date}    = $email->header("Date") // "";

		$msg->{loaded}  = 1;
	}
}

# -----------------------------
# Main loop
# -----------------------------
while (1) {

	# -----------------------------
	# Auto-refresh every 10 seconds
	# -----------------------------
	if (time() - $last_refresh >= 10) {
		# Remember currently selected message ID
		my $sel_id = $queue[$sel]{id} if $sel <= $#queue;

		# Refresh queue
		my %old_ids = map { $_->{id} => $_ } @queue;
		@queue = get_queue_list();
		foreach my $msg (@queue) {
			if (exists $old_ids{$msg->{id}}) {
				$msg->{subject} = $old_ids{$msg->{id}}->{subject};
				$msg->{to}      = $old_ids{$msg->{id}}->{to};
				$msg->{date}    = $old_ids{$msg->{id}}->{date};
				$msg->{loaded}  = $old_ids{$msg->{id}}->{loaded};
			}
		}

		# Restore selection to same message
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
		$scroll = 0 if $scroll > $sel;

		$last_refresh = time();
	}

	# -----------------------------
	# Sort queue
	# -----------------------------
	my $sel_id = $queue[$sel]{id} if $sel <= $#queue;

	if ($sort_mode eq 'subject') {
		@queue = sort { $sort_order * (lc($a->{subject}) cmp lc($b->{subject})) } @queue;
	} else {
		@queue = sort { $sort_order * ($a->{date} cmp $b->{date}) } @queue;
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
	printw("Postfix Queue Viewer (Arrow keys: navigate, d: delete, q: quit, t: sort time, s: sort subject)\n");
	printw("--------------------------------------------------------------------------------\n");

	my $end = $scroll + $max_y;
	$end = $#queue if $end > $#queue;

	for my $i ($scroll .. $end) {
		my $msg = $queue[$i];
		load_headers($msg);

		# Show only the part before @ in the To field
		my $to_short = $msg->{to} =~ /^(.*?)@/ ? $1 : $msg->{to};

		my $prefix = ($i == $sel) ? "> " : "  ";
		printw(sprintf "%s%-8s %-25.25s %-25.25s %-30.30s\n",
			$prefix, $msg->{id}, $msg->{date}, $to_short, $msg->{subject});
	}

	# -----------------------------
	# Handle input
	# -----------------------------
	my $ch = getch();
	if (defined $ch) {
		if ($ch eq 'q') { last; }

		# Delete selected mail
		elsif ($ch eq 'd') {
			my $qid = $queue[$sel]{id};
			my $ret = system("/usr/sbin/postsuper -d $qid");
			if ($ret == 0) {
				splice(@queue, $sel, 1);
				$sel = 0 if $sel > $#queue;
				$scroll = 0 if $scroll > $sel;
			} else {
				move($max_y + 3, 0);
				printw("Failed to delete mail $qid. Ensure sudo/root privileges.");
				getch();
			}
		}

		# Arrow key navigation
		elsif ($ch eq Curses::KEY_DOWN) {
			$sel++ if $sel < $#queue;
			$scroll++ if $sel > $scroll + $max_y;
		}
		elsif ($ch eq Curses::KEY_UP) {
			$sel-- if $sel > 0;
			$scroll-- if $sel < $scroll;
		}

		# Sort toggles
		elsif ($ch eq 't') {
			if ($sort_mode eq 'time') { $sort_order *= -1; }
			else { $sort_mode = 'time'; $sort_order = 1; }
		}
		elsif ($ch eq 's') {
			if ($sort_mode eq 'subject') { $sort_order *= -1; }
			else { $sort_mode = 'subject'; $sort_order = 1; }
		}
	}
}

# -----------------------------
# Cleanup
# -----------------------------
endwin();
