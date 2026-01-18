#!/usr/bin/perl
use strict;
use warnings;
use Curses;
use Email::MIME;

# -----------------------------
# Step 1: Get queue list
# -----------------------------
my @queue;
open my $pq, "-|", "postqueue -p" or die "Cannot run postqueue: $!";
while (<$pq>) {
	if (/^([A-F0-9]+)\*?\s+(\S+)\s+/) {
		push @queue, {
			id	 => $1,
			from   => $2,
			loaded => 0,
			subject => '',
			to	  => '',
			date	=> '',
		};
	}
}
close $pq;

# -----------------------------
# Step 2: Initialize Curses
# -----------------------------
initscr();
noecho();
cbreak();
keypad(stdscr, 1);

my $sel = 0;
my $scroll = 0;
my $max_y = getmaxy(stdscr) - 2;

sub load_headers {
	my ($msg) = @_;
	return if $msg->{loaded};

	open my $pc, "-|", "postcat -q $msg->{id}" or return;
	my $raw = do { local $/; <$pc> };
	close $pc;

	my $email = eval { Email::MIME->new($raw) };
	if ($email) {
		$msg->{subject} = $email->header("Subject") // "";
		$msg->{to}	  = $email->header("To")	  // "";
		$msg->{date}	= $email->header("Date")	// "";
		$msg->{loaded}  = 1;
	}
}

# -----------------------------
# Step 3: Main loop
# -----------------------------
while (1) {
	clear();
	printw("Postfix Queue Viewer (Arrow keys: navigate, d: delete, q: quit)\n");
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
	if ($ch eq 'q') { last; }
	elsif ($ch eq 'd') {
		my $qid = $queue[$sel]{id};
		system("sudo postsuper -d $qid");
		splice(@queue, $sel, 1);
		$sel = 0 if $sel > $#queue;
		$scroll = 0 if $scroll > $sel;
	}
	# Arrow key handling
	elsif ($ch eq Curses::KEY_DOWN) {
		$sel++ if $sel < $#queue;
		$scroll++ if $sel > $scroll + $max_y;
	}
	elsif ($ch eq Curses::KEY_UP) {
		$sel-- if $sel > 0;
		$scroll-- if $sel < $scroll;
	}
}

# -----------------------------
# Step 4: Cleanup
# -----------------------------
endwin();
