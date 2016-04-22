package Sessions;

use strict;
use Exporter;
use IPC::SharedMem;
use POSIX; # For floor() / ceil()
use Getopt::Long;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $DEBUG);

$VERSION      = 0.1;
$DEBUG        = 0;
@ISA          = qw(Exporter);
@EXPORT       = qw(fuzzy plus_or_minus toggle_bool
                  sec_to_human error_msg debug_msg extend_session
                  read_config write_config init_state
                  fisher_yates_shuffle
                );
@EXPORT_OK    = @EXPORT;

sub error_msg {
  # Standardize error messages
  my $message = shift;
  # 0 is a non-fatal error, non-zero will exit with that error
  my $err_lvl = shift || 0;
  if ($err_lvl =~ /[^0-9]/) {
    printf STDERR "Error: err_lvl '%s' not understood; exiting\n",$err_lvl;
    $err_lvl = 1;
  }

  printf STDERR "Error: %s\n",$message;
  if ($err_lvl != 0) {
    exit $err_lvl;
  }
  return undef;
}

sub debug_msg {
  # Standardize debug messages
  my $message = shift;

  if ($DEBUG) {
    printf "DEBUG: %s\n",$message;
  }
  return undef;
}

sub read_config {
  # Attempt to open and read in values from specified config file
  # Returns hash ref containing configuration
  my $conf_file = shift;
  my %options   = ();

  if (open my $conf_fh,'<',"$conf_file") {
    while (<$conf_fh>) {
      my $line = $_;

      # Remove leading / trailing white-space
      $line =~ s/^\s+//;
      $line =~ s/\s+$//;

      # Skip empty and commented lines
      next if ($line =~ /^$/);
      next if ($line =~ /^#/);
      # squish whitespace
      $line =~ s/\s+/\ /g;

      my ($option,$values) = split(/\ /,$line,2);
      foreach my $value (split(/:/,$values)) {
        $value =~ s/~/$ENV{HOME}/;
        $value =~ s/\$HOME/$ENV{HOME}/i;
        if (defined $options{$option}) {
          $options{$option} = join(':',$options{$option},$value);
        } else {
          $options{$option} = $value;
        }
      }
    }
    close $conf_fh;
  } else {
    error_msg("Unable to open $conf_file: $!",1);
  }

  return \%options;
}

sub write_config {
  my $config_file = shift;
  my $config      = shift;

  if (open my $config_fh,'>',"$config_file") {
    foreach my $option (sort { $a cmp $b } keys %$config) {
      foreach my $value (sort { $a cmp $b } split(/:/,$$config{$option})) {
        printf $config_fh "%s %s\n", $option, $value;
      }
    }
  } else {
    error_msg("Unable to open $config_file: $!",2);
  }

  return 1;
}

sub fuzzy {
  my $number  = shift;
  my $degree  = shift;

  return $number if ($degree <= 0);

  for (1 .. int(rand($degree))) {
    # Control how far to deviate from $num
    my $skew = int(rand(3))+2;
    # Lean toward 0 or 2 * $num
    my $lean = int(rand(4))+2;
    # This is not superflous; the rand($lean) below will favor this direction
    my $point = 1;
    # "Flip a coin" to determine the direction of the lean
    if (int(rand(2))) {
      $point = -1;
    }

    my $result = $number;

    for (1 .. int($number)) {
      if (!int(rand($skew))) {
        if (int(rand($lean))) {
          $result += $point;
        } else {
          $result += ($point * -1);
        }
      }
    }

    $number = $result;
  }
  return $number;
}

sub plus_or_minus {
  my $num     = shift;

  my $result  = 0;

  for (1 .. int($num)) {
    if (int(rand(2))) {
      $result += int(rand(2));
    } else {
      $result -= int(rand(2));
    }
  }

  return $result;
}

sub toggle_bool {
  my $value = shift;
  if ($value) {
    return 0;
  }
  return 1;
}

sub sec_to_human {
  my $secs = shift;
  if ($secs >= 365*24*60*60) {
    return sprintf '%.1f years', $secs/(365+*24*60*60);
  } elsif ($secs >= 24*60*60) {
    return sprintf '%.1f days', $secs/(24*60*60);
  } elsif ($secs >= 60*60) {
    return sprintf '%.1f hours', $secs/(60*60);
  } elsif ($secs >= 60) {
    return sprintf '%.1f minutes', $secs/60;
  } else {
    return sprintf '%.1f seconds', $secs;
  }
}

sub extend_session {
  my $state = shift;

  my $pace    = $$state{pace_cur};
  my $min     = $$state{pace_min};
  my $max     = $$state{pace_max};
  my $dir     = $$state{pace_dir};
  my $down    = $$state{go_down};
  my $low     = $$state{endzone_low};
  my $high    = $$state{endzone_high};
  my $field   = $max - $min;
  my $percent = ($pace - $min) / $field;

  # Determine the direction for this extension
  if ($down > 0) {
    $down--;
  } else {
    if ($percent*100 >= $high) {
      $dir = 1;
    } elsif ($percent*100 <= $low) {
      $dir = -1;
    } elsif (($$state{time_elapsed} / $$state{time_max}) > rand(1)) {
      $dir = 1;
    } else {
      $dir = -1;
      if (int(rand(2))) {
        $down = 3 + plus_or_minus(2);
      }
    }
  }

  if ($pace == $max or !int(rand($max - $pace))) {
    # Decrease pace at least once
    $down = 0;
    $dir = -1;
    if (int(rand(2))) {
      $down = 3 + plus_or_minus(2);
    }
  }

  if ($pace == $min or !int(rand($pace - $min))) {
    # Increase pace at least once
    $down = 0;
    $dir = 1;
  }

  # Lower size of step as pace approaches either end, largest at 50%
  my @steps = (34, 21, 13, 8, 5, 3, 2, 1);
  my $step_tier = 0;
  if ($dir > 0) {
    $step_tier = sprintf "%.0f", $percent * $#steps;
  } else {
    $step_tier = sprintf "%.0f", (1 - $percent) * $#steps;
  }
  my $step = fuzzy($steps[$step_tier],$$state{fuzzify});
  $step = 2 if ($step < 2);

  # Set initial new pace
  my $new = $pace + ($step * $dir);

  if ($percent*100 >= $high and $dir < 0) {
    $new = $min + int($field * (fuzzy(50,1) / 100));
    if (!int(rand(4))) {
      $new = $min + int($field * (fuzzy($low,1) / 100));
      $down = 3 + plus_or_minus(2);
    }
  }

  if ($percent*100 <= $low and $dir > 0) {
    $new = $min + int($field * (fuzzy(50,1) / 100));
    if (!int(rand(4))) {
      $new = $min + int($field * (fuzzy($high,1) / 100));
    }
  }

  if ($pace < $max and $$state{time_elapsed} > $$state{time_min} and
      $down <= 0 and $dir < 0 and !int(rand(6))) {
    $new = $max;
  }

  if ($new >= $max) {
    $new = $max;
  }

  if ($new <= $min) {
    $new = $min;
  }

  if ($pace == $new) {
    error_msg("pace = new pace; bad math somewhere",0);
  }

  my $new_pct = ($new - $min) / $field;
  my $delta_pct = abs($new - $pace) / $field;

  my $steady;
  if ($dir > 0) {
    $steady = sprintf "%.0f", $new_pct * 20;
  } else {
    $steady = sprintf "%.0f", (1 - $new_pct) * 20;
  }
  $steady = fuzzy($steady,$$state{fuzzify});
  $steady = 2 if ($steady < 2);

  my $build = fuzzy(int(30 * $delta_pct),$$state{fuzzify});
  $build = 2 if ($build < 2);

  if ($new >= ($max - 10)) {
    $steady = int($steady * 1.5);
  }

  if ($new == $max) {
    $steady = int($steady * 1.5);
  }

  my $time_added =
      change_pace($$state{session_script},$pace,$new,$build,$steady);

  $$state{time_elapsed} += $time_added;
  $$state{pace_cur} = $new;
  $$state{pace_dir} = $dir;

  write_config($$state{state_file},$state);
  return $time_added;
}

sub change_pace {
  my $session_file  = shift;
  my $start_bpm     = shift;
  my $final_bpm     = shift;
  my $build_time    = shift;
  my $peak_time     = shift;

  my $diff_bpm      = abs($start_bpm - $final_bpm);
  my $avg_bpm       = int(($start_bpm + $final_bpm) / 2);

  my $build_beats   = ceil(($avg_bpm / 60) * $build_time);
  my $peak_beats    = ceil(($final_bpm / 60) * $peak_time);

  my $actual_build_time = 0;
  my $actual_peak_time  = 0;

  # Beats per step and an extra beat every nth step
  my $beat_per_step = 0;
  my $beat_nth_step = 0;

  if ($diff_bpm > 0) {
    $beat_per_step = floor($build_beats/$diff_bpm);
    if ($build_beats % $diff_bpm != 0) {
      $beat_nth_step = floor($diff_bpm / ($build_beats % $diff_bpm));
    }
  }

  if (open my $session_fh,'>>',"$session_file") {
    printf $session_fh "# start: %s\n", $start_bpm;
    foreach my $step (0 .. ($diff_bpm-1)) {
      my $beats = $beat_per_step;
      if ($beat_nth_step && !($step % $beat_nth_step)) {
        # Add an extra beat, because this is the nth bpm step
        $beats++;
      }
      if ($beats) {
        my $bpm = $start_bpm + $step;
        if ($start_bpm > $final_bpm) {
          $bpm = $start_bpm - $step;
        }
        $actual_build_time += $beats / ($bpm / 60);
        printf $session_fh "%g %g/4 2/8\n",$beats,$bpm;
      }
    }

    printf $session_fh "# build_time: %0.2fs (%gs requested)\n",
            $actual_build_time, $build_time;
    printf $session_fh "%g %g/4 2/8\n",$peak_beats,$final_bpm;
    $actual_peak_time = $peak_beats / ($final_bpm / 60);
    printf $session_fh "# peak_time: %0.2fs (%gs requested)\n",
            $actual_peak_time, $peak_time;
  } else {
    error_msg("Unable to open $session_file: $!",3);
  }
  return $actual_peak_time+$actual_build_time;
}

sub init_state {
  # Provide config file name to initialize state or
  # the current state file name to modify state
  my $config_file = shift;

  my $config      = read_config("$config_file");
  my $state       = $config;

  $$state{win}    = 0;
  $$state{lose}   = 0;
  $$state{wrong}  = 0;
  $$state{score}  = 100;

  GetOptions(
    "max=i"       => \$$state{pace_max},
    "min=i"       => \$$state{pace_min},
    "pace=i"      => \$$state{pace_cur},
    "short=f"     => \$$state{time_min},
    "long=f"      => \$$state{time_max},
    "sides=i"     => \$$state{dice_sides},
    "dice=i"      => \$$state{dice_count},
    "high=i"      => \$$state{extra_high},
    "low=i"       => \$$state{extra_low},
    "bonus=i"     => \$$state{bonus_chance},
    "bonus_max=i" => \$$state{bonus_max},
    "low_end=i"   => \$$state{endzone_low},
    "high_end=i"  => \$$state{endzone_high},
    "fuzzify=i"   => \$$state{fuzzify},
    "prize_on"    => \$$state{prize_on},
    "green=i"     => \$$state{window_green},
    "yellow=i"    => \$$state{window_yellow},
    "win=i"       => \$$state{win},
    "lose=i"      => \$$state{lose},
    "score=i"     => \$$state{score},
    "wrong=i"     => \$$state{wrong},
  ) or die("Error in args.\n");

  # Initialize counters and defaults
  $$state{matches_cur}      = 0;
  $$state{matches}          = 0;
  $$state{matches_gap}      = 0;
  $$state{streak}           = 0;
  $$state{last_score}       = -1;
  $$state{countdown}        = 0;
  $$state{go_for_green}     = 0;
  $$state{green_light}      = 0;
  $$state{greens}           = 0;
  $$state{prize_armed}      = 0;
  $$state{prize_rank}       = 0;
  $$state{time_armed}       = 0;
  $$state{time_rank}        = 0;
  $$state{time_added}       = 0;
  $$state{lube_armed}       = 0;
  $$state{end_game}         = 0;
  $$state{bonus_rank}       = 0;
  $$state{buffer}           = $$state{buffer_reset};
  $$state{bonus_jump}       = $$state{buffer_reset};
  $$state{lubed}            = 0;

  $$state{matches_max}  = fuzzy($$state{matches_max},$$state{fuzzify}+2);

  return $state;
}

sub fisher_yates_shuffle {
  my $array = shift;
  my $i;

  if (@$array < 2) {
    return;
  }

  for ($i = @$array; --$i; ) {
    my $j = int rand ($i+1);
    next if $i == $j;
    @$array[$i,$j] = @$array[$j,$i];
  }
}

1;
