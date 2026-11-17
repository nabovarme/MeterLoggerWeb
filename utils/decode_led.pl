#!/usr/bin/env perl
use strict;
use warnings;

my $HALF_BIT_MS = 15.0; # Must match OPTICAL_HALF_BIT_MS in user/led.c

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
my @frames_pure_blue;
while (read($fh, my $buf, $frame_bytes) == $frame_bytes) {
	my @rgb = unpack('C*', $buf);
	my (@val, @pure);
	for my $i (0 .. ($W * $H - 1)) {
		my $r = $rgb[$i * 3];
		my $g = $rgb[$i * 3 + 1];
		my $b = $rgb[$i * 3 + 2];
		my $blue_excess = $b - int(($r + $g) / 2);
		push @val, ($blue_excess > 0 ? ($b + $blue_excess * 1.5) : $b);
		push @pure, ($blue_excess > 10 ? $blue_excess : 0);
	}
	push @frames_blue, \@val;
	push @frames_pure_blue, \@pure;
}
close($fh);

my $num_frames = scalar @frames_blue;
die "Too few frames decoded ($num_frames)\n" if $num_frames < 20;
printf "Decoded %d frames\n", $num_frames;

my $lag = int(($HALF_BIT_MS / $dt_ms) + 0.5);
$lag = 1 if $lag < 1;

sub box3_at {
	my ($frame, $cx, $cy) = @_;
	my ($sum, $cnt) = (0, 0);
	for my $dy (-1 .. 1) {
		my $y = $cy + $dy;
		next if $y < 0 || $y >= $H;
		my $row = $y * $W;
		for my $dx (-1 .. 1) {
			my $x = $cx + $dx;
			next if $x < 0 || $x >= $W;
			$sum += $frame->[$row + $x];
			$cnt++;
		}
	}
	return $cnt > 0 ? ($sum / $cnt) : 0;
}

# 3. Build cumulative pure-blue blink-energy map across the entire clip
my @energy = (0) x ($W * $H);
for my $f ($lag .. $num_frames - 1) {
	my $cur = $frames_pure_blue[$f];
	my $prv = $frames_pure_blue[$f - $lag];
	for my $p (0 .. ($W * $H - 1)) {
		my $d = abs($cur->[$p] - $prv->[$p]);
		$energy[$p] += $d * $d if $d > 8;
	}
}

my ($best_x, $best_y, $best_e) = (int($W / 2), int($H / 2), -1);
for my $y (2 .. $H - 3) {
	for my $x (2 .. $W - 3) {
		my $e = 0;
		for my $dy (-2 .. 2) {
			my $row = ($y + $dy) * $W;
			for my $dx (-2 .. 2) {
				$e += $energy[$row + $x + $dx];
			}
		}
		if ($e > $best_e) {
			$best_e = $e;
			$best_x = $x;
			$best_y = $y;
		}
	}
}

my ($seed_f, $best_delta) = ($lag, -1);
for my $f ($lag .. $num_frames - 1) {
	my $d = abs(box3_at($frames_pure_blue[$f], $best_x, $best_y)
	          - box3_at($frames_pure_blue[$f - $lag], $best_x, $best_y));
	if ($d > $best_delta) {
		$best_delta = $d;
		$seed_f = $f;
	}
}

printf "Locked onto blue LED casing at pixel (x=%d, y=%d), peak frame %d (t=%.0f ms, delta=%.1f)\n",
	$best_x, $best_y, $seed_f, $seed_f * $dt_ms, $best_delta;

# 4. Smooth velocity-clamped tracker + stationary wide diffused ROI
my @track_x = ($best_x) x $num_frames;
my @track_y = ($best_y) x $num_frames;
my $step_r = 2;
my $max_drift = 18;
my $min_blink_delta = $best_delta * 0.25;
$min_blink_delta = 8.0 if $min_blink_delta < 8.0;

my ($cx, $cy) = ($best_x, $best_y);
for my $f ($seed_f .. $num_frames - 1) {
	my $cur = $frames_pure_blue[$f];
	my $prv = $frames_pure_blue[$f - $lag];
	my ($best_d, $bx, $by) = (0, $cx, $cy);

	for my $dy (-$step_r .. $step_r) {
		my $y = $cy + $dy;
		next if $y < 1 || $y >= $H - 1 || abs($y - $best_y) > $max_drift;
		for my $dx (-$step_r .. $step_r) {
			my $x = $cx + $dx;
			next if $x < 1 || $x >= $W - 1 || abs($x - $best_x) > $max_drift;
			my $d = abs(box3_at($cur, $x, $y) - box3_at($prv, $x, $y));
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

($cx, $cy) = ($best_x, $best_y);
for (my $f = $seed_f - 1; $f >= 0; $f--) {
	my $ref_f = $f + $lag < $num_frames ? $f + $lag : $num_frames - 1;
	my $cur = $frames_pure_blue[$f];
	my $nxt = $frames_pure_blue[$ref_f];
	my ($best_d, $bx, $by) = (0, $cx, $cy);

	for my $dy (-$step_r .. $step_r) {
		my $y = $cy + $dy;
		next if $y < 1 || $y >= $H - 1 || abs($y - $best_y) > $max_drift;
		for my $dx (-$step_r .. $step_r) {
			my $x = $cx + $dx;
			next if $x < 1 || $x >= $W - 1 || abs($x - $best_x) > $max_drift;
			my $d = abs(box3_at($cur, $x, $y) - box3_at($nxt, $x, $y));
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

sub extract_signal {
	my ($tx_ref, $ty_ref, $half_box, $top_k) = @_;
	my @sig;
	for my $f (0 .. $num_frames - 1) {
		my $tx = $tx_ref->[$f];
		my $ty = $ty_ref->[$f];
		my $frame = $frames_blue[$f];
		my @patch;
		for my $dy (-$half_box .. $half_box) {
			my $y = $ty + $dy;
			next if $y < 0 || $y >= $H;
			my $row = $y * $W;
			for my $dx (-$half_box .. $half_box) {
				my $x = $tx + $dx;
				next if $x < 0 || $x >= $W;
				push @patch, $frame->[$row + $x];
			}
		}
		@patch = sort { $b <=> $a } @patch;
		my $n = @patch < $top_k ? scalar(@patch) : $top_k;
		my $sum = 0;
		$sum += $patch[$_] for 0 .. $n - 1;
		push @sig, ($sum / $n);
	}
	return \@sig;
}

my @fixed_x = ($best_x) x $num_frames;
my @fixed_y = ($best_y) x $num_frames;

my @candidates = (
	[ "tracked", extract_signal(\@track_x, \@track_y, 4, 12) ],
	[ "wide-roi", extract_signal(\@fixed_x, \@fixed_y, 7, 16) ],
);

my %decoded_packets;
my $found_any = 0;

sub is_printable_payload {
	my ($bytes_ref) = @_;
	for my $b (@$bytes_ref) {
		return 0 unless ($b >= 0x20 && $b <= 0x7E) || $b == 0x0A || $b == 0x0D || $b == 0x09 || $b == 0x00;
	}
	return 1;
}

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
					if ($rx_crc == $calc_crc && is_printable_payload(\@payload_bytes)) {
						my $payload_str = pack('C*', @payload_bytes);
						$payload_str =~ s/\0+$//;
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

# 5. Local-Normalized Slip-Tolerant PLL (adapts to iPhone Auto-Exposure changes mid-video!)
my $win_half = int(400.0 / $dt_ms); # +/- 400 ms sliding window (~12 bit periods)

for my $cand (@candidates) {
	my ($cname, $sig_ref) = @$cand;
	my @raw = @$sig_ref;

	# Compute local sliding-window min/max so AE gain drops don't hide later bursts
	my @norm;
	for my $i (0 .. $#raw) {
		my $lo = $i - $win_half < 0 ? 0 : $i - $win_half;
		my $hi = $i + $win_half > $#raw ? $#raw : $i + $win_half;
		my ($lmin, $lmax) = (1e9, -1e9);
		for my $j ($lo .. $hi) {
			$lmin = $raw[$j] if $raw[$j] < $lmin;
			$lmax = $raw[$j] if $raw[$j] > $lmax;
		}
		if (($lmax - $lmin) < 10.0) {
			push @norm, -1.0;
		} else {
			push @norm, (($raw[$i] - $lmin) / ($lmax - $lmin)) * 2.0 - 1.0;
		}
	}

	my $sample_at = sub {
		my ($t_ms) = @_;
		my $idx = $t_ms / $dt_ms;
		return -1.0 if $idx < 0 || $idx >= $#norm;
		my $i0 = int($idx);
		my $frac = $idx - $i0;
		return $norm[$i0] * (1.0 - $frac) + $norm[$i0 + 1] * $frac;
	};

	for my $thresh (-0.15, 0.0, 0.15, 0.30, -0.30) {
		my @edges;
		for my $i (1 .. $#norm) {
			my $v0 = $norm[$i - 1] - $thresh;
			my $v1 = $norm[$i] - $thresh;
			if ($v0 <= 0 && $v1 > 0) {
				my $frac = ($v1 - $v0) != 0 ? (-$v0 / ($v1 - $v0)) : 0.5;
				push @edges, [ ($i - 1 + $frac) * $dt_ms, 1 ];
			} elsif ($v0 > 0 && $v1 <= 0) {
				my $frac = ($v0 - $v1) != 0 ? ($v0 / ($v0 - $v1)) : 0.5;
				push @edges, [ ($i - 1 + $frac) * $dt_ms, 0 ];
			}
		}

		next if @edges < 30;
		my $total_ms = $#norm * $dt_ms;

		for (my $th = 14.0; $th <= 17.5; $th += 0.1) {
			my $tbit = $th * 2.0;
			my $tol  = $th * 0.55;

			for my $start_idx (0 .. $#edges - 32) {
				my @bits;
				my $t_cur = $edges[$start_idx][0];
				push @bits, $edges[$start_idx][1];
				my $e_ptr = $start_idx + 1;
				my $misses = 0;

				while ($t_cur + $tbit < $total_ms && @bits < 560) {
					my $t_target = $t_cur + $tbit;
					while ($e_ptr <= $#edges && $edges[$e_ptr][0] < $t_target - $tol) {
						$e_ptr++;
					}

					my ($best_e, $best_err) = (-1, 1e9);
					my $scan = $e_ptr;
					while ($scan <= $#edges && $edges[$scan][0] <= $t_target + $tol) {
						my $err = abs($edges[$scan][0] - $t_target);
						if ($err < $best_err) {
							$best_err = $err;
							$best_e = $scan;
						}
						$scan++;
					}

					if ($best_e != -1) {
						push @bits, $edges[$best_e][1];
						$t_cur = 0.65 * $edges[$best_e][0] + 0.35 * $t_target;
						$e_ptr = $best_e + 1;
						$misses = 0;
					} else {
						my $s_before = $sample_at->($t_target - $th * 0.45);
						my $s_after  = $sample_at->($t_target + $th * 0.45);
						push @bits, ($s_before > $s_after ? 0 : 1);
						$t_cur = $t_target;
						last if ++$misses > 3;
					}
				}

				if (@bits >= 32) {
					try_decode_bitstream(join('', @bits), sprintf("%s LocalPLL T=%.2f th=%.2f", $cname, $th, $thresh));
				}
			}
			last if $found_any;
		}
		last if $found_any;
	}
	last if $found_any;
}

if (!$found_any) {
	print "\nNo valid CRC8 frame found. Dumping all pulses after t=1000 ms:\n";
	my ($sig_ref) = @{$candidates[0]}[1];
	my @raw = @$sig_ref;
	my ($cur_v, $cur_c, $start_f, $printed) = (0, 1, 0, 0);
	for my $f (1 .. $#raw) {
		my $lo = $f - $win_half < 0 ? 0 : $f - $win_half;
		my $hi = $f + $win_half > $#raw ? $#raw : $f + $win_half;
		my ($lmin, $lmax) = (1e9, -1e9);
		for my $j ($lo .. $hi) {
			$lmin = $raw[$j] if $raw[$j] < $lmin;
			$lmax = $raw[$j] if $raw[$j] > $lmax;
		}
		my $v = (($lmax - $lmin) >= 10.0 && $raw[$f] > ($lmin + $lmax) * 0.5) ? 1 : 0;
		if ($v == $cur_v) {
			$cur_c++;
		} else {
			if ($start_f * $dt_ms >= 950) {
				printf "  t=%6.1f ms | level=%d | dur=%5.1f ms\n",
					$start_f * $dt_ms, $cur_v, $cur_c * $dt_ms;
				last if ++$printed >= 90;
			}
			$cur_v = $v;
			$cur_c = 1;
			$start_f = $f;
		}
	}
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
