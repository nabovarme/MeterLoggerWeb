#!/usr/bin/perl
use strict;
use warnings;
use Curses;
use Email::MIME;
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
# Lazy-load headers
# -----------------------------
sub load_headers {
	my ($msg) = @_;
	return if $msg->{loaded};

	open my $pc, "-|", "postcat -q $msg->{id}" or return;
	my $raw = do { local $/; <$pc> };
	close $pc;

	my $email = eval { Email::MIME->new($raw) };
	if ($email) {
		$msg->{subject} = $email->header("Subject") // "";
		$msg->{to}      = $email->header("To")      // "";
		$msg->{date}    = $email->header("Date")    // "";
		$msg->{loaded}  = 1;
	}
}

# -----------------------------
# Main loop
# -----------------------------
while (1) {
	# Auto-refresh every 10 seconds
	if (time() - $last_refresh >= 10) {
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
		$sel = 0 if $sel > $#queue;
		$scroll = 0 if $scroll > $sel;
		$last_refresh = time();
	}

	clear();
	printw("Postfix Queue Viewer (Arrow keys: navigate, d: delete, q: quit, auto-refresh every 10s)\n");
	printw("--------------------------------------------------------------------------------\n");

	my $end = $scroll + $max_y;
	$end = $#queue if $end > $#queue;

	for my $i ($scroll .. $end) {
		my $msg = $queue[$i];
		load_headers($msg);
		my $prefix = ($i == $sel) ? "> " : "  ";
		printw(sprintf "%s%-8s %-25.25s %-25.25s %-30.30s\n",
			$prefix, $msg->{id}, $msg->{date}, $msg->{to}, $msg->{subject});
	}

	my $ch = getch();
	if (defined $ch) {
		if ($ch eq 'q') { last; }
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
		elsif ($ch eq Curses::KEY_DOWN) {
			$sel++ if $sel < $#queue;
			$scroll++ if $sel > $scroll + $max_y;
		}
		elsif ($ch eq Curses::KEY_UP) {
			$sel-- if $sel > 0;
			$scroll-- if $sel < $scroll;
		}
	}
}

# -----------------------------
# Cleanup
# -----------------------------
endwin();
