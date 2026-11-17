#!/usr/bin/env perl
use strict;
use warnings;

my $HALF_BIT_MS = 15.0; # Must match OPTICAL_HALF_BIT_MS in user/led.c

my $video = $ARGV[0] or die "Usage: $0 <video.MOV>\n";
die "File not found: $video\n" unless -f $video;

# 1. Detect FPS via ffmpeg probe output
my $probe = `ffmpeg -i "$video" 2>&1`;
my ($fps) = $probe =~ /(\d+(?:\.\d+)?)\s*fps/;
die "Could not determine FPS from video\n" unless $fps && $fps > 0;

printf "Video FPS: %.2f (half-bit = %.1f ms -> %.2f frames/half-bit)\n",
	$fps, $HALF_BIT_MS, ($fps * $HALF_BIT_MS / 1000.0);

# 2. Stream downscaled 160x90 RGB24 frames from ffmpeg
my ($W, $H) = (160, 90);
my $frame_bytes = $W * $H * 3;
open(my $fh, '-|', 'ffmpeg', '-v', 'quiet', '-i', $video,
	 '-vf', "scale=${W}:${H}", '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-')
	or die "Failed to run ffmpeg: $!\n";
binmode($fh);

my @frames_blue;
while (read($fh, my $buf, $frame_bytes) == $frame_bytes) {
	# Extract blue channel (byte offset 2, 5, 8, ... in RGB24)
	my @rgb  = unpack('C*', $buf);
	my @blue = map { $rgb[$_ * 3 + 2] } 0 .. ($W * $H - 1);
	push @frames_blue, \@blue;
}
close($fh);

my $num_frames = scalar @frames_blue;
die "No frames decoded from video\n" if $num_frames < 10;

# 3. Auto-locate the blinking LED by finding the pixel with max variance over time
my ($best_idx, $best_var) = (0, -1);
for my $p (0 .. ($W * $H - 1)) {
	my $sum = 0;
	$sum += $_->[$p] for @frames_blue;
	my $mean = $sum / $num_frames;

	my $var = 0;
	for my $f (@frames_blue) {
		my $d = $f->[$p] - $mean;
		$var += $d * $d;
	}
	if ($var > $best_var) {
		$best_var = $var;
		$best_idx = $p;
	}
}

my $cx = $best_idx % $W;
my $cy = int($best_idx / $W);
printf "Detected blinking LED at scaled pixel (x=%d, y=%d)\n", $cx, $cy;

# 4. Extract mean blue intensity in a 5x5 ROI around (cx, cy) per frame
my @signal;
my ($min_v, $max_v) = (1e9, -1e9);
for my $f (@frames_blue) {
	my ($sum, $cnt) = (0, 0);
	for my $dy (-2 .. 2) {
		my $y = $cy + $dy;
		next if $y < 0 || $y >= $H;
		for my $dx (-2 .. 2) {
			my $x = $cx + $dx;
			next if $x < 0 || $x >= $W;
			$sum += $f->[$y * $W + $x];
			$cnt++;
		}
	}
	my $val = $sum / $cnt;
	push @signal, $val;
	$min_v = $val if $val < $min_v;
	$max_v = $val if $val > $max_v;
}

# 5. Adaptive thresholding + run-length encoding in milliseconds
my $thresh = ($min_v + $max_v) / 2.0;
my @levels = map { $_ > $thresh ? 1 : 0 } @signal;

my $ms_per_frame = 1000.0 / $fps;
my @runs;
my ($cur_val, $cur_cnt) = ($levels[0], 1);
for my $v (@levels[1 .. $#levels]) {
	if ($v == $cur_val) {
		$cur_cnt++;
	} else {
		push @runs, [ $cur_val, $cur_cnt * $ms_per_frame ];
		$cur_val = $v;
		$cur_cnt = 1;
	}
}
push @runs, [ $cur_val, $cur_cnt * $ms_per_frame ];

# 6. Quantize run durations into half-bits (1x or 2x HALF_BIT_MS)
my @half_bits;
for my $r (@runs) {
	my ($val, $dur_ms) = @$r;
	my $n_half = int(($dur_ms / $HALF_BIT_MS) + 0.5);
	if ($n_half == 1 || $n_half == 2) {
		push @half_bits, ($val) x $n_half;
	} else {
		push @half_bits, -1; # Idle gap between packets
	}
}

# 7. Decode Manchester pairs (1,0 -> 0; 0,1 -> 1)
my @bits;
my $i = 0;
while ($i < $#half_bits) {
	my ($a, $b) = ($half_bits[$i], $half_bits[$i + 1]);
	if ($a == 1 && $b == 0) {
		push @bits, 0;
		$i += 2;
	} elsif ($a == 0 && $b == 1) {
		push @bits, 1;
		$i += 2;
	} else {
		$i++;
	}
}

# 8. Search for SOF (0x7E = 01111110) and verify CRC8
my $bit_str = join('', @bits);
my $pos = index($bit_str, '01111110');
if ($pos == -1) {
	die "SOF (0x7E) not found. Record in 240 fps Slow-Mo with AE/AF Lock.\n";
}

my $payload_bits = substr($bit_str, $pos + 8);
my @bytes;
for (my $b = 0; $b + 8 <= length($payload_bits); $b += 8) {
	push @bytes, oct('0b' . substr($payload_bits, $b, 8));
}

die "Too few bytes decoded\n" if @bytes < 3;

my $pkt_len = $bytes[0];
die sprintf("Incomplete packet (expected %d payload bytes, got %d)\n", $pkt_len, scalar(@bytes) - 2)
	if @bytes < 1 + $pkt_len + 1;

my @payload_bytes = @bytes[1 .. $pkt_len];
my $rx_crc      = $bytes[1 + $pkt_len];
my $calc_crc    = crc8($pkt_len, @payload_bytes);
my $payload_str = pack('C*', @payload_bytes);

if ($rx_crc == $calc_crc) {
	printf "OK (CRC 0x%02X): %s\n", $rx_crc, $payload_str;
} else {
	printf "CRC mismatch! Received 0x%02X, calculated 0x%02X | Raw: %s\n",
		$rx_crc, $calc_crc, $payload_str;
}

sub crc8 {
	my @data = @_;
	my $crc = 0;
	for my $b (@data) {
		$crc ^= $b;
		for (1 .. 8) {
			$crc = ($crc & 0x80) ? ((($crc << 1) ^ 0x07) & 0xFF) : (($crc << 1) & 0xFF);
		}
	}
	return $crc;
}
