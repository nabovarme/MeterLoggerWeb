#!/usr/bin/env perl
use strict;
use warnings;

my $HALF_BIT_MS = 15.0; # Actual measured half-bit period from ESP8266 FRC1 timer

my $video = $ARGV[0] or die "Usage: $0 <video.MOV>\n";
die "File not found: $video\n" unless -f $video;

# 1. Detect stream FPS via ffprobe
my $rate = `ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate,r_frame_rate -of csv=p=0 "$video" 2>&1`;
my $fps = 240.0;
if ($rate =~ /(\d+)\/(\d+)/ && $2 > 0 && $1 > 0) {
	$fps = $1 / $2;
}
my $dt_ms = 1000.0 / $fps;

printf "Stream FPS: %.2f (%.2f ms/frame -> %.2f frames/half-bit)\n",
	$fps, $dt_ms, ($HALF_BIT_MS / $dt_ms);

# 2. Stream downscaled 160x90 RGB24 frames
my ($W, $H) = (160, 90);
my $frame_bytes = $W * $H * 3;
open(my $fh, '-|', 'ffmpeg', '-v', 'quiet', '-i', $video,
	'-fps_mode', 'passthrough', '-vf', "scale=${W}:${H}",
	'-f', 'rawvideo', '-pix_fmt', 'rgb24', '-')
	or die "Failed to run ffmpeg: $!\n";
binmode($fh);

my @frames_blue;
while (read($fh, my $buf, $frame_bytes) == $frame_bytes) {
	my @rgb = unpack('C*', $buf);
	my @val = map {
		my $r = $rgb[$_ * 3];
		my $g = $rgb[$_ * 3 + 1];
		my $b = $rgb[$_ * 3 + 2];
		my $blue_excess = $b - int(($r + $g) / 2);
		$blue_excess > 0 ? ($b + $blue_excess) : $b;
	} 0 .. ($W * $H - 1);
	push @frames_blue, \@val;
}
close($fh);

my $num_frames = scalar @frames_blue;
die "Too few frames decoded ($num_frames)\n" if $num_frames < 20;
printf "Decoded %d frames\n", $num_frames;

# 3. Find the strongest blinking seed pixel and frame using 3-frame temporal change
my ($seed_f, $seed_idx, $best_delta) = (3, 0, -1);
for my $f (3 .. $num_frames - 1) {
	my $cur = $frames_blue[$f];
	my $prv = $frames_blue[$f - 3];
	for my $p (0 .. ($W * $H - 1)) {
		my $d = $cur->[$p] - $prv->[$p];
		if ($d > $best_delta) {
			$best_delta = $d;
			$seed_idx = $p;
			$seed_f = $f;
		}
	}
}

my $seed_x = $seed_idx % $W;
my $seed_y = int($seed_idx / $W);
printf "Locked onto blinking LED at frame %d (t=%.0f ms), pixel (x=%d, y=%d, delta=%d)\n",
	$seed_f, $seed_f * $dt_ms, $seed_x, $seed_y, $best_delta;

# 4. Track LED center forward and backward from seed_f using temporal blink activity
my @track_x = ($seed_x) x $num_frames;
my @track_y = ($seed_y) x $num_frames;
my $search_r = 10;
my $min_blink_delta = int($best_delta * 0.25);
$min_blink_delta = 35 if $min_blink_delta < 35;

my ($cx, $cy) = ($seed_x, $seed_y);
for my $f ($seed_f .. $num_frames - 1) {
	my $cur = $frames_blue[$f];
	my $prv = $frames_blue[$f - 3];
	my ($best_d, $bx, $by) = (0, $cx, $cy);

	my $y0 = $cy - $search_r < 0 ? 0 : $cy - $search_r;
	my $y1 = $cy + $search_r >= $H ? $H - 1 : $cy + $search_r;
	my $x0 = $cx - $search_r < 0 ? 0 : $cx - $search_r;
	my $x1 = $cx + $search_r >= $W ? $W - 1 : $cx + $search_r;

	for my $y ($y0 .. $y1) {
		my $row = $y * $W;
		for my $x ($x0 .. $x1) {
			my $d = abs($cur->[$row + $x] - $prv->[$row + $x]);
			if ($d > $best_d) {
				$best_d = $d;
				$bx = $x;
				$by = $y;
			}
		}
	}
	if ($best_d >= $min_blink_delta) {
		$cx = $bx;
		$cy = $by;
	}
	$track_x[$f] = $cx;
	$track_y[$f] = $cy;
}

($cx, $cy) = ($seed_x, $seed_y);
for (my $f = $seed_f - 1; $f >= 0; $f--) {
	my $ref_f = $f + 3 < $num_frames ? $f + 3 : $num_frames - 1;
	my $cur = $frames_blue[$f];
	my $nxt = $frames_blue[$ref_f];
	my ($best_d, $bx, $by) = (0, $cx, $cy);

	my $y0 = $cy - $search_r < 0 ? 0 : $cy - $search_r;
	my $y1 = $cy + $search_r >= $H ? $H - 1 : $cy + $search_r;
	my $x0 = $cx - $search_r < 0 ? 0 : $cx - $search_r;
	my $x1 = $cx + $search_r >= $W ? $W - 1 : $cx + $search_r;

	for my $y ($y0 .. $y1) {
		my $row = $y * $W;
		for my $x ($x0 .. $x1) {
			my $d = abs($cur->[$row + $x] - $nxt->[$row + $x]);
			if ($d > $best_d) {
				$best_d = $d;
				$bx = $x;
				$by = $y;
			}
		}
	}
	if ($best_d >= $min_blink_delta) {
		$cx = $bx;
		$cy = $by;
	}
	$track_x[$f] = $cx;
	$track_y[$f] = $cy;
}

my @signal;
my ($g_min, $g_max) = (1e9, -1e9);
my ($min_x, $max_x, $min_y, $max_y) = ($seed_x, $seed_x, $seed_y, $seed_y);

for my $f (0 .. $num_frames - 1) {
	my $tx = $track_x[$f];
	my $ty = $track_y[$f];
	$min_x = $tx if $tx < $min_x;
	$max_x = $tx if $tx > $max_x;
	$min_y = $ty if $ty < $min_y;
	$max_y = $ty if $ty > $max_y;

	my $frame = $frames_blue[$f];
	my @patch;
	for my $dy (-2 .. 2) {
		my $y = $ty + $dy;
		next if $y < 0 || $y >= $H;
		my $row = $y * $W;
		for my $dx (-2 .. 2) {
			my $x = $tx + $dx;
			next if $x < 0 || $x >= $W;
			push @patch, $frame->[$row + $x];
		}
	}
	@patch = sort { $b <=> $a } @patch;
	my $top_n = @patch < 4 ? scalar(@patch) : 4;
	my $sum = 0;
	$sum += $patch[$_] for 0 .. $top_n - 1;
	my $v = $sum / $top_n;

	push @signal, $v;
	$g_min = $v if $v < $g_min;
	$g_max = $v if $v > $g_max;
}

printf "Tracked LED motion span: x=[%d..%d] (%d px), y=[%d..%d] (%d px)\n",
	$min_x, $max_x, ($max_x - $min_x), $min_y, $max_y, ($max_y - $min_y);
printf "Tracked ROI intensity range: min=%.1f, max=%.1f\n", $g_min, $g_max;

my %decoded_packets;
my $found_any = 0;

# Helper: validate candidate bit string for SOF (0x7E) + LEN + PAYLOAD + CRC8
sub try_decode_bitstream {
	my ($bit_str, $tag) = @_;
	for my $invert (0, 1) {
		my $s = $invert ? ($bit_str =~ tr/01/10/r) : $bit_str;
		my $pos = index($s, '01111110'); # SOF 0x7E
		while ($pos != -1) {
			my $payload_bits = substr($s, $pos + 8);
			my @bytes;
			for (my $b = 0; $b + 8 <= length($payload_bits); $b += 8) {
				push @bytes, oct('0b' . substr($payload_bits, $b, 8));
			}
			if (@bytes >= 4) {
				my $pkt_len = $bytes[0];
				if ($pkt_len >= 2 && $pkt_len <= 64 && @bytes >= 1 + $pkt_len + 1) {
					my @payload_bytes = @bytes[1 .. $pkt_len];
					my $rx_crc        = $bytes[1 + $pkt_len];
					my $calc_crc      = crc8($pkt_len, @payload_bytes);
					my $payload_str   = pack('C*', @payload_bytes);
					if ($rx_crc == $calc_crc) {
						my $key = "$rx_crc:$payload_str";
						if (!$decoded_packets{$key}++) {
							printf "OK (%s, CRC 0x%02X, invert=%d): %s\n",
								$tag, $rx_crc, $invert, $payload_str;
							$found_any = 1;
						}
					}
				}
			}
			$pos = index($s, '01111110', $pos + 1);
		}
	}
}

# 5. Method A: Clamped Manchester RLE across candidate half-bit periods & biases
my $win_long = int(2000.0 / $dt_ms);
for my $th_nom (10.5, 15.0) {
	for my $use_global (1, 0) {
		for my $bias (0.30, 0.40, 0.50, 0.60, 0.70) {
			my @levels;
			for my $i (0 .. $#signal) {
				my ($lmin, $lmax) = ($g_min, $g_max);
				if (!$use_global) {
					my $lo = $i - $win_long < 0 ? 0 : $i - $win_long;
					my $hi = $i + $win_long > $#signal ? $#signal : $i + $win_long;
					($lmin, $lmax) = (1e9, -1e9);
					for my $j ($lo .. $hi) {
						$lmin = $signal[$j] if $signal[$j] < $lmin;
						$lmax = $signal[$j] if $signal[$j] > $lmax;
					}
				}
				if (($lmax - $lmin) < 15.0) {
					push @levels, 0;
				} else {
					my $thresh = $lmin + ($lmax - $lmin) * $bias;
					push @levels, ($signal[$i] > $thresh ? 1 : 0);
				}
			}

			my @runs;
			my ($cur_v, $cur_c) = ($levels[0], 1);
			for my $v (@levels[1 .. $#levels]) {
				if ($v == $cur_v) {
					$cur_c++;
				} else {
					push @runs, [ $cur_v, $cur_c * $dt_ms ];
					$cur_v = $v;
					$cur_c = 1;
				}
			}
			push @runs, [ $cur_v, $cur_c * $dt_ms ];

			my @half_bits;
			for my $r (@runs) {
				my ($val, $dur) = @$r;
				if ($dur >= $th_nom * 0.45 && $dur <= $th_nom * 1.55) {
					push @half_bits, $val;
				} elsif ($dur > $th_nom * 1.55 && $dur <= $th_nom * 2.85) {
					push @half_bits, $val, $val;
				} else {
					push @half_bits, -1;
				}
			}

			for my $offset (0, 1) {
				my @bits;
				my $i = $offset;
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
				my $mode = $use_global ? "global" : "win2s";
				try_decode_bitstream(join('', @bits), "RLE T=${th_nom} $mode bias=$bias off=$offset");
			}
		}
	}
}

# 6. Method B: Global-normalized T_half & start-edge grid search (9.5 ms .. 16.0 ms)
if (!$found_any) {
	my $g_span = $g_max - $g_min;
	die "Signal contrast too low ($g_span)\n" if $g_span < 15.0;
	my $g_mid = ($g_min + $g_max) / 2.0;
	my @norm = map { ($_ - $g_mid) / ($g_span / 2.0) } @signal;

	sub sample_at {
		my ($t_ms) = @_;
		my $idx = $t_ms / $dt_ms;
		return -1.0 if $idx < 0 || $idx >= $#norm;
		my $i0 = int($idx);
		my $frac = $idx - $i0;
		return $norm[$i0] * (1.0 - $frac) + $norm[$i0 + 1] * $frac;
	}

	my @edges;
	for my $i (1 .. $#norm) {
		if (($norm[$i - 1] <= 0 && $norm[$i] > 0) || ($norm[$i - 1] > 0 && $norm[$i] <= 0)) {
			my $denom = $norm[$i] - $norm[$i - 1];
			my $frac = $denom != 0 ? (-$norm[$i - 1] / $denom) : 0.5;
			push @edges, ($i - 1 + $frac) * $dt_ms;
		}
	}

	my $total_ms = $#norm * $dt_ms;
	for (my $th = 9.5; $th <= 16.0; $th += 0.05) {
		my $tbit = $th * 2.0;
		for my $e (@edges) {
			for my $shift (0.0, -$th) {
				my $t0 = $e + $shift;
				next if $t0 < 0 || $t0 + 36 * $tbit > $total_ms;

				my @bits;
				my $clk = $t0;
				while ($clk + $tbit < $total_ms && @bits < 560) {
					my $s1 = sample_at($clk + $th * 0.5);
					my $s2 = sample_at($clk + $th * 1.5);
					push @bits, ($s1 > $s2 ? 0 : 1);
					$clk += $tbit;
				}
				try_decode_bitstream(join('', @bits), sprintf("Grid T=%.2f", $th));
			}
		}
	}
}

print "No valid CRC8 frame found.\n" unless $found_any;

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
