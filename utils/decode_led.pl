#!/usr/bin/env perl
# Optical Manchester decoder for ESP8266 GPIO2 blue LED telemetry recorded at high FPS (e.g. 240 fps Slow-Mo).
# Expects framing: [0xAA, 0xAA preamble] [0x7E SOF] [LEN] [ASCII PAYLOAD...] [CRC8]
use strict;
use warnings;

my $HALF_BIT_MS = 15.0; # Must match OPTICAL_HALF_BIT_MS in user/led.c

my $video = $ARGV[0] or die "Usage: $0 <video.MOV>\n";
die "File not found: $video\n" unless -f $video;

# 1. Detect stream FPS via ffprobe to convert frame indices into wall-clock milliseconds
my $rate = `ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate,r_frame_rate -of csv=p=0 "$video" 2>&1`;
my $fps = 240.0;
if ($rate =~ /(\d+)\/(\d+)/ && $2 > 0 && $1 > 0) {
	$fps = $1 / $2;
}
my $dt_ms = 1000.0 / $fps;

printf "Stream FPS: %.2f (%.2f ms/frame -> %.2f frames/half-bit)\n",
	$fps, $dt_ms, ($HALF_BIT_MS / $dt_ms);

# 2. Stream downscaled 160x90 RGB24 frames via ffmpeg.
# -fps_mode passthrough preserves every raw sensor frame without dropping or duplicating VFR frames.
my ($W, $H) = (160, 90);
my $frame_bytes = $W * $H * 3;
open(my $fh, '-|', 'ffmpeg', '-v', 'quiet', '-i', $video,
	'-fps_mode', 'passthrough', '-vf', "scale=${W}:${H}",
	'-f', 'rawvideo', '-pix_fmt', 'rgb24', '-')
	or die "Failed to run ffmpeg: $!\n";
binmode($fh);

# Extract two per-frame intensity maps:
# - @frames_blue: blue-boosted brightness used for high-SNR bit waveform extraction
# - @frames_pure_blue: strict blue-excess channel (rejects white/warm room glare) used for ROI tracking
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

# Frame lag corresponding to one Manchester half-bit (~3-4 frames at 240 fps)
my $lag = int(($HALF_BIT_MS / $dt_ms) + 0.5);
$lag = 1 if $lag < 1;

# Compute mean intensity in a 3x3 pixel window around (cx, cy)
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

# Locate the coordinates of maximum half-bit blink energy within [f_start .. f_end].
# Differencing frames separated by $lag isolates the blinking LED from static background lights.
sub find_peak_in_range {
	my ($f_start, $f_end) = @_;
	$f_start = $lag if $f_start < $lag;
	$f_end = $num_frames - 1 if $f_end >= $num_frames;

	my @energy = (0) x ($W * $H);
	for my $f ($f_start .. $f_end) {
		my $cur = $frames_pure_blue[$f];
		my $prv = $frames_pure_blue[$f - $lag];
		for my $p (0 .. ($W * $H - 1)) {
			my $d = abs($cur->[$p] - $prv->[$p]);
			$energy[$p] += $d * $d if $d > 8;
		}
	}

	# Smooth blink energy over a 5x5 block to center on diffused translucent casing glow
	my ($bx, $by, $be) = (int($W / 2), int($H / 2), -1);
	for my $y (2 .. $H - 3) {
		for my $x (2 .. $W - 3) {
			my $e = 0;
			for my $dy (-2 .. 2) {
				my $row = ($y + $dy) * $W;
				for my $dx (-2 .. 2) {
					$e += $energy[$row + $x + $dx];
				}
			}
			if ($e > $be) {
				$be = $e;
				$bx = $x;
				$by = $y;
			}
		}
	}

	# Find the sharpest transition frame within this chunk to seed bidirectional tracking
	my ($sf, $bd) = ($f_start, -1);
	for my $f ($f_start .. $f_end) {
		my $d = abs(box3_at($frames_pure_blue[$f], $bx, $by)
		          - box3_at($frames_pure_blue[$f - $lag], $bx, $by));
		if ($d > $bd) {
			$bd = $d;
			$sf = $f;
		}
	}
	return ($bx, $by, $sf, $bd, $be);
}

# 3. Chunked smooth tracker (re-anchors every 1.5 s to handle handheld camera motion and dark gaps)
my $chunk_frames = int(1500.0 / $dt_ms);
my @track_x = (0) x $num_frames;
my @track_y = (0) x $num_frames;

my ($global_bx, $global_by, $global_sf, $global_bd, $global_be) = find_peak_in_range($lag, $num_frames - 1);
printf "Global peak blue LED casing at (x=%d, y=%d), frame %d (t=%.0f ms, delta=%.1f)\n",
	$global_bx, $global_by, $global_sf, $global_sf * $dt_ms, $global_bd;

for (my $c0 = 0; $c0 < $num_frames; $c0 += $chunk_frames) {
	my $c1 = $c0 + $chunk_frames - 1;
	$c1 = $num_frames - 1 if $c1 >= $num_frames;

	# Fall back to global peak coordinates during idle chunks when the LED is not transmitting
	my ($bx, $by, $sf, $bd, $be) = find_peak_in_range($c0, $c1);
	if ($bd < 10.0) {
		($bx, $by, $sf, $bd) = ($global_bx, $global_by, int(($c0 + $c1) / 2), $global_bd);
	}

	my $step_r = 2;      # Max pixel step per frame (prevents jumping to distant reflections)
	my $max_drift = 35;  # Max drift from chunk anchor
	my $min_d = $bd * 0.22;
	$min_d = 8.0 if $min_d < 8.0;

	# Track forward from seed frame to end of chunk
	my ($cx, $cy) = ($bx, $by);
	for my $f ($sf .. $c1) {
		my $cur = $frames_pure_blue[$f];
		my $prv = $f - $lag >= 0 ? $frames_pure_blue[$f - $lag] : $cur;
		my ($best_d, $nx, $ny) = (0, $cx, $cy);
		for my $dy (-$step_r .. $step_r) {
			my $y = $cy + $dy;
			next if $y < 1 || $y >= $H - 1 || abs($y - $by) > $max_drift;
			for my $dx (-$step_r .. $step_r) {
				my $x = $cx + $dx;
				next if $x < 1 || $x >= $W - 1 || abs($x - $bx) > $max_drift;
				my $d = abs(box3_at($cur, $x, $y) - box3_at($prv, $x, $y));
				if ($d > $best_d) {
					$best_d = $d;
					$nx = $x;
					$ny = $y;
				}
			}
		}
		if ($best_d >= $min_d) {
			$cx = $nx;
			$cy = $ny;
		}
		$track_x[$f] = $cx;
		$track_y[$f] = $cy;
	}

	# Track backward from seed frame to start of chunk
	($cx, $cy) = ($bx, $by);
	for (my $f = $sf - 1; $f >= $c0; $f--) {
		my $ref_f = $f + $lag < $num_frames ? $f + $lag : $num_frames - 1;
		my $cur = $frames_pure_blue[$f];
		my $nxt = $frames_pure_blue[$ref_f];
		my ($best_d, $nx, $ny) = (0, $cx, $cy);
		for my $dy (-$step_r .. $step_r) {
			my $y = $cy + $dy;
			next if $y < 1 || $y >= $H - 1 || abs($y - $by) > $max_drift;
			for my $dx (-$step_r .. $step_r) {
				my $x = $cx + $dx;
				next if $x < 1 || $x >= $W - 1 || abs($x - $bx) > $max_drift;
				my $d = abs(box3_at($cur, $x, $y) - box3_at($nxt, $x, $y));
				if ($d > $best_d) {
					$best_d = $d;
					$nx = $x;
					$ny = $y;
				}
			}
		}
		if ($best_d >= $min_d) {
			$cx = $nx;
			$cy = $ny;
		}
		$track_x[$f] = $cx;
		$track_y[$f] = $cy;
	}
}

# Average the top_k brightest pixels inside a (2*half_box+1)^2 ROI for each frame.
# Top-K pooling captures the glowing LED hotspot even with minor sub-pixel tracking jitter.
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

my @fixed_x = ($global_bx) x $num_frames;
my @fixed_y = ($global_by) x $num_frames;

# Evaluate both motion-tracked ROI and stationary wide ROI signals
my @candidates = (
	[ "chunk-tracked", extract_signal(\@track_x, \@track_y, 5, 14) ],
	[ "wide-roi",      extract_signal(\@fixed_x, \@fixed_y, 9, 20) ],
);

my %exact_packets;
my %soft_packets; # key -> [flips, quality_score, tag, rx_crc, invert, payload_str]
my $found_exact = 0;

# Ensure decoded payload contains only printable ASCII or standard whitespace/NUL
sub is_printable_payload {
	my ($bytes_ref) = @_;
	for my $b (@$bytes_ref) {
		return 0 unless ($b >= 0x20 && $b <= 0x7E) || $b == 0x0A || $b == 0x0D || $b == 0x09 || $b == 0x00;
	}
	return 1;
}

# Heuristic score used to rank soft-decision CRC8 candidates toward plausible log strings
sub ascii_plausibility {
	my ($str) = @_;
	my $score = 0;
	for my $ch (split //, $str) {
		if ($ch =~ /[A-Za-z0-9 _\-().:]/) {
			$score += 2;
		} else {
			$score -= 3;
		}
	}
	return $score;
}

# Parse [LEN] [PAYLOAD...] [CRC8] from a bit slice and verify CRC8 + printable ASCII
sub check_frame_bytes {
	my ($s_slice, $pkt_len) = @_;
	my $need_bits = (1 + $pkt_len + 1) * 8;
	return if length($s_slice) < $need_bits;

	my @bytes;
	for (my $b = 0; $b < $need_bits; $b += 8) {
		push @bytes, oct('0b' . substr($s_slice, $b, 8));
	}
	my @payload_bytes = @bytes[1 .. $pkt_len];
	my $rx_crc        = $bytes[1 + $pkt_len];
	my $calc_crc      = crc8($pkt_len, @payload_bytes);

	return unless $rx_crc == $calc_crc && is_printable_payload(\@payload_bytes);
	my $payload_str = pack('C*', @payload_bytes);
	$payload_str =~ s/\0+$//;
	return ($rx_crc, $payload_str);
}

# Scan decoded bitstream (in both normal and inverted polarity) for SOF 0x7E frames
sub try_decode_bitstream {
	my ($bit_str, $confs_ref, $tag) = @_;
	for my $invert (0, 1) {
		my $s = $invert ? ($bit_str =~ tr/01/10/r) : $bit_str;
		my $pos = index($s, '01111110'); # SOF 0x7E
		while ($pos != -1) {
			my $frame_start = $pos + 8;
			if ($frame_start + 32 <= length($s)) {
				my $pkt_len = oct('0b' . substr($s, $frame_start, 8));
				my $need_bits = (1 + $pkt_len + 1) * 8;

				if ($pkt_len >= 2 && $pkt_len <= 64 && $frame_start + $need_bits <= length($s)) {
					my $slice = substr($s, $frame_start, $need_bits);

					# 1. Exact CRC8 match (0 bit errors)
					if (my ($rx_crc, $payload_str) = check_frame_bytes($slice, $pkt_len)) {
						my $key = "$rx_crc:$payload_str";
						if (!$exact_packets{$key}++) {
							printf "OK (%s, CRC 0x%02X, invert=%d): %s\n",
								$tag, $rx_crc, $invert, $payload_str;
							$found_exact = 1;
						}
					} elsif (!$found_exact && defined $confs_ref) {
						# 2. Soft-decision recovery: flip 1 or 2 lowest-confidence bits and re-verify CRC8
						my @weak = sort { $confs_ref->[$frame_start + $a] <=> $confs_ref->[$frame_start + $b] }
							(8 .. $need_bits - 1);
						my $top1 = @weak < 12 ? scalar(@weak) : 12;
						my $top2 = @weak < 8  ? scalar(@weak) : 8;

						# Single-bit soft correction
						for my $i (0 .. $top1 - 1) {
							my $cand_s = $slice;
							my $idx1 = $weak[$i];
							substr($cand_s, $idx1, 1, substr($cand_s, $idx1, 1) eq '0' ? '1' : '0');
							if (my ($rx_crc, $payload_str) = check_frame_bytes($cand_s, $pkt_len)) {
								my $q = 1000 + ascii_plausibility($payload_str) - $confs_ref->[$frame_start + $idx1];
								my $key = "$rx_crc:$payload_str";
								if (!$soft_packets{$key} || $q > $soft_packets{$key}[1]) {
									$soft_packets{$key} = [1, $q, "$tag [1-bit soft fix]", $rx_crc, $invert, $payload_str];
								}
							}
						}

						# Two-bit soft correction
						for my $i (0 .. $top2 - 2) {
							for my $j ($i + 1 .. $top2 - 1) {
								my $cand_s = $slice;
								my ($idx1, $idx2) = ($weak[$i], $weak[$j]);
								substr($cand_s, $idx1, 1, substr($cand_s, $idx1, 1) eq '0' ? '1' : '0');
								substr($cand_s, $idx2, 1, substr($cand_s, $idx2, 1) eq '0' ? '1' : '0');
								if (my ($rx_crc, $payload_str) = check_frame_bytes($cand_s, $pkt_len)) {
									my $q = ascii_plausibility($payload_str)
									      - $confs_ref->[$frame_start + $idx1]
									      - $confs_ref->[$frame_start + $idx2];
									my $key = "$rx_crc:$payload_str";
									if (!$soft_packets{$key} || $q > $soft_packets{$key}[1]) {
										$soft_packets{$key} = [2, $q, "$tag [2-bit soft fix]", $rx_crc, $invert, $payload_str];
									}
								}
							}
						}
					}
				}
			}
			$pos = index($s, '01111110', $pos + 1);
		}
	}
}

# 4. Half-Bit Box-Integral Matched Filter + Sliding Midpoint Calibration
for my $cand (@candidates) {
	my ($cname, $sig_ref) = @$cand;
	my @raw = @$sig_ref;
	my $n = scalar @raw;

	# Sub-frame linear interpolation at arbitrary timestamp t_ms
	my $raw_at = sub {
		my ($t_ms) = @_;
		my $idx = $t_ms / $dt_ms;
		return $raw[0] if $idx <= 0;
		return $raw[$n - 1] if $idx >= $n - 1;
		my $i0 = int($idx);
		my $frac = $idx - $i0;
		return $raw[$i0] * (1.0 - $frac) + $raw[$i0 + 1] * $frac;
	};

	# Integrate interior of first half-bit [-0.70*th .. -0.20*th] vs second [+0.20*th .. +0.70*th].
	# Sampling away from edges avoids plastic casing rise/decay blur; positive diff = 0->1 (bit 1).
	my $halfbit_diff = sub {
		my ($t_mid, $th) = @_;
		my $m1 = ($raw_at->($t_mid - $th * 0.70) + $raw_at->($t_mid - $th * 0.45) + $raw_at->($t_mid - $th * 0.20)) / 3.0;
		my $m2 = ($raw_at->($t_mid + $th * 0.20) + $raw_at->($t_mid + $th * 0.45) + $raw_at->($t_mid + $th * 0.70)) / 3.0;
		return $m2 - $m1;
	};

	# Find local derivative extrema as candidate mid-bit transition start points
	my @deriv = (0.0) x $n;
	for my $i (1 .. $n - 2) {
		$deriv[$i] = ($raw[$i + 1] - $raw[$i - 1]) * 0.5;
	}

	my @slope_peaks;
	for my $i (2 .. $n - 3) {
		my $d = $deriv[$i];
		if ($d > 6.0 && $d >= $deriv[$i - 1] && $d >= $deriv[$i + 1]) {
			push @slope_peaks, $i * $dt_ms;
		} elsif ($d < -6.0 && $d <= $deriv[$i - 1] && $d <= $deriv[$i + 1]) {
			push @slope_peaks, $i * $dt_ms;
		}
	}

	next if @slope_peaks < 20;
	my $total_ms = ($n - 1) * $dt_ms;

	# Sweep T_half in 5 us steps across 15.800 .. 16.200 ms to lock onto exact ESP8266 timer period
	for (my $th = 15.800; $th <= 16.200; $th += 0.005) {
		my $tbit = $th * 2.0;

		for my $t_start (@slope_peaks) {
			next if $t_start + 40 * $tbit > $total_ms;

			my $t_cur = $t_start;
			my @diffs;
			while ($t_cur + $th < $total_ms && @diffs < 620) {
				my $d0 = $halfbit_diff->($t_cur, $th);
				push @diffs, $d0;

				# Unbiased Manchester early-late gate: nudge phase toward peak |m2 - m1|
				my ($best_shift, $best_mag) = (0.0, abs($d0));
				for my $sh (-3.5, -2.0, -1.0, 1.0, 2.0, 3.5) {
					my $mag = abs($halfbit_diff->($t_cur + $sh, $th));
					if ($mag > $best_mag * 1.08) {
						$best_mag = $mag;
						$best_shift = $sh;
					}
				}
				$t_cur += $tbit + $best_shift * 0.25;
			}

			next if @diffs < 40;

			# Sliding-window (+/- 12 bits) midpoint normalization removes asymmetric glow-tail bias
			# and tracks camera auto-exposure changes across long bursts
			my (@bits, @confs);
			my $win = 12;
			for my $k (0 .. $#diffs) {
				my $lo = $k - $win < 0 ? 0 : $k - $win;
				my $hi = $k + $win > $#diffs ? $#diffs : $k + $win;
				my ($dmin, $dmax) = (1e9, -1e9);
				for my $j ($lo .. $hi) {
					$dmin = $diffs[$j] if $diffs[$j] < $dmin;
					$dmax = $diffs[$j] if $diffs[$j] > $dmax;
				}
				my $mid = ($dmax + $dmin) * 0.5;
				my $norm_d = $diffs[$k] - $mid;
				push @bits, ($norm_d > 0 ? 1 : 0);
				push @confs, abs($norm_d);
			}

			try_decode_bitstream(join('', @bits), \@confs, sprintf("%s BoxMatched T=%.3f", $cname, $th));
			last if $found_exact;
		}
		last if $found_exact;
	}
	last if $found_exact;
}

# Print best ranked soft-decision match only if no 0-error exact CRC8 frame was found
if (!$found_exact) {
	if (%soft_packets) {
		my ($best_key) = sort {
			$soft_packets{$a}[0] <=> $soft_packets{$b}[0] ||
			$soft_packets{$b}[1] <=> $soft_packets{$a}[1]
		} keys %soft_packets;
		my ($flips, $q, $tag, $rx_crc, $invert, $payload_str) = @{$soft_packets{$best_key}};
		printf "OK (%s, CRC 0x%02X, invert=%d): %s\n", $tag, $rx_crc, $invert, $payload_str;
	} else {
		print "No valid CRC8 frame found.\n";
	}
}

# Standard CRC-8/SMBUS (polynomial 0x07, initial value 0x00), matching optical_crc8() in user/led.c
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
