package Sessions;

use strict;
use Exporter;
use Getopt::Long;
use IPC::SharedMem;
use Net::Twitter;
use POSIX qw(strftime floor ceil);
use Time::Local;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $DEBUG);

$VERSION      = 0.1;
$DEBUG        = 0;
@ISA          = qw(Exporter);
# Functions used in scripts
@EXPORT       = qw(
                    debug_msg
                    error_msg
                    extend_session
                    fisher_yates_shuffle
                    fuzzy
                    get_remaining_sessions
                    get_sessions_by_date
                    get_today
                    init_session_state
                    pick_images
                    play_metronome_script
                    plus_or_minus
                    read_config
                    sec_to_human
                    sec_to_human_precise
                    sexy_slideshow
                    toggle_bool
                    twitters
                    write_config
                );
@EXPORT_OK    = @EXPORT;

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
    error_msg("Err 6: Unable to open $session_file: $!",3);
  }
  return $actual_peak_time+$actual_build_time;
}

sub debug_msg {
  # Standardize debug messages
  my $message = shift;

  if ($DEBUG) {
    printf "DEBUG: %s\n",$message;
  }
  return undef;
}

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
    if ($$state{session_length} > $$state{time_min}) {
      $dir = 1;
    } elsif ($$state{session_length} / $$state{time_min} > rand(1)) {
      $dir = 1;
    } else {
      $dir = -1;
      if (int(rand(2))) {
        $down = int(rand(4));
      }
    }

    if ($percent*100 >= $high) {
      $dir = 1;
    }

    if ($percent*100 <= $low) {
      $dir = -1;
    }
  }

  if ($pace == $max or !int(rand($max - $pace))) {
    $down = 0;
    $dir = -1;
    if (int(rand(2))) {
      $down = int(rand(4));
    }
  }

  if ($pace == $min or !int(rand($pace - $min))) {
    $down = 0;
    $dir = 1;
  }

  # Lower size of step as pace approaches either end, largest at 50%
  my @steps = (23, 17, 12, 8, 5, 3, 2, 1);
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
    }

    if (!int(rand(4))) {
      $down = int(rand(3));
    }
  }

  if ($percent*100 <= $low and $dir > 0) {
    $new = $min + int($field * (fuzzy(50,1) / 100));
    if (!int(rand(4))) {
      $new = $min + int($field * (fuzzy($high,1) / 100));
    }
  }

  if ($pace < $max and $$state{session_length} > $$state{time_min} and
      $down <= 0 and $dir < 0 and !int(rand(6))) {
    $new = $max;
  }

  if ($new > $max) {
    $new = $max;
  }

  if ($new < $min) {
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

  $$state{session_length} += $time_added;
  $$state{pace_cur} = $new;
  $$state{pace_dir} = $dir;

  write_config($$state{state_file},$state);
  return $time_added;
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

sub get_images_from_dirs {
  my $dirs = shift;

  my @images = ();
  foreach my $glob (split/:/,$dirs) {
    foreach my $dir (glob $glob) {
      if (opendir my $dir_fh,"$dir") {
        my @files = grep { /.(jpe?g|gif|bmp|nef|cr2|png)$/i } readdir $dir_fh;
        closedir $dir_fh;
        @files = map { "$dir/" . $_ } @files;
        push @images, @files;
      } else {
        error_msg("get_images_from_dirs: Unable to opendir $dir: $!",0);
      }
    }
  }

  return @images;
}

sub get_remaining_sessions {
  my $state     = shift;
  my $date      = shift;

  my $sessions  = get_sessions_by_date($state,$date);
  my $required  = $$state{daily_required};
  my $attempted = 0;
  my $passed    = 0;

  foreach my $session (sort keys %$sessions) {
    if ($$sessions{$session}{undone} > 0) {
      if ($required == 0) {
        $required++;
      }
      $required++;
    } else {
      if ($required > 0) {
        $required--;
      }
      $passed++;
    }
    $attempted++;
  }

  return $required;
}

sub get_sessions_by_date {
  my $state = shift;
  my $date  = shift;

  my ($year,$mon,$day) = split(/-/,$date);
  my ($hour,$min) = split(/_/,$$state{day_start});
  my $start = timelocal(0,$min,$hour,$day,$mon-1,$year);
  my $end   = $start + 24 * 60 * 60;

  my %sessions = ();
  if (open my $log,'<',$$state{session_log}) {
    while (my $line = <$log>) {
      my ($time,$length,$added,$done,$undone,$armed,$icy) = split(/:/,$line);
      if ($time >= $start and $time < $end) {
        $sessions{$time} = {
          length    =>  $length,
          done      =>  $done,
          undone    =>  $undone,
          icy_armed =>  $armed,
          icy_used  =>  $icy
        };
      }
    }
  }
  return \%sessions;
}

sub get_today {
  my $start = shift;

  my $date = strftime "%F", localtime(time);
  my ($year,$mon,$day) = split(/-/,$date);
  my ($hour,$min) = split(/_/,$start);
  my $start_secs = timelocal(0,$min,$hour,$day,$mon-1,$year);
  # If start is in the future, it's after midnight; need to time travel.
  if ($start_secs > time) {
    $start_secs -= 24 * 60 * 60;
  }

  return strftime "%F", localtime($start_secs);
}

sub init_session_state {
  # Provide config file name to initialize state or
  # the current state file name to modify state
  my $config_file = shift;

  my $config      = read_config("$config_file");
  my $state       = $config;

  $$state{win}    = 0;
  $$state{lose}   = 0;
  $$state{wrong}  = 0;
  $$state{score}  = 100;
  $$state{prize_armed} = 0;

  GetOptions(
    "max=i"       => \$$state{pace_max},
    "min=i"       => \$$state{pace_min},
    "pace=i"      => \$$state{pace_cur},
    "short=f"     => \$$state{time_min},
    "long=f"      => \$$state{time_max},
    "low_end=i"   => \$$state{endzone_low},
    "high_end=i"  => \$$state{endzone_high},
    "fuzzify=i"   => \$$state{fuzzify},
    "prizes"      => \$$state{prize_armed},
    "green=i"     => \$$state{green_pics},
    "greens=i"    => \$$state{greens},
    "yellow=i"    => \$$state{yellow_pics},
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
  $$state{countdown}        = -1;
  $$state{go_for_green}     = 0;
  $$state{green_light}      = 0;
  $$state{prize_rank}       = 0;
  $$state{time_added}       = 0;
  $$state{time_next}        = 0;
  $$state{lube_next}        = 0;
  $$state{end_game}         = 0;
  $$state{session_length}   = 0;
  $$state{buffer}           = $$state{buffer_reset};
  $$state{bonus_bump}       = $$state{buffer_reset};
  $$state{bonus_rank}       = 0;
  $$state{bonus}            = 0;
  $$state{lubed}            = 0;
  $$state{icy_used}         = 0;
  $$state{prize_until}      = 0;
  $$state{multiplier}       = int(rand($$state{lose}))+1;

  $$state{matches_max}      = fuzzy($$state{matches_max},$$state{fuzzify}+2);
  $$state{matches_max}      = 15;
  $$state{time_start}       = time();
  $$state{go_down}          = 3 + plus_or_minus(2);
  $$state{pace_dir}         = -1;

  if (int(rand($$state{go_down}))) {
    $$state{go_down}  = 0;
    $$state{pace_dir} = 1;
  }

  my $time_min = $$state{time_min} * $$state{time_unit};
  my $time_max = $$state{time_max} * $$state{time_unit};

  if ($$state{fuzzify}) {
    $time_min = fuzzy($time_min,$$state{fuzzify});
    $time_max = fuzzy($time_max,$$state{fuzzify});
  }

  if ($$state{wrong} and $$state{lose} and $$state{win}) {
    my @times = ();

    for (1 .. $$state{lose} + $$state{win} * 2) {
      push @times,int(rand($$state{wrong} * $$state{time_unit}))+1;
    }
    @times = sort { $a <=> $b } @times;

    my @lows  = @times[0 .. $$state{lose}-1];
    my @highs = @times[$#times - $$state{win} + 1 .. $#times];

    my @times = @times[$$state{lose} .. $#times - $$state{win}];

    printf "Time Spread: %s [ %s ] %s\n","@lows","@times","@highs";

    my $time_sum = 0;
    foreach my $time (@times) {
      $time_sum += $time;
    }

    my $time_extra = int($time_sum / scalar(@times));

    if ($$state{fuzzify}) {
      $time_extra = fuzzy($time_extra,$$state{fuzzify});
    }

    $time_max += $time_extra;
  }

  $$state{time_min} = $time_min;
  $$state{time_max} = $time_max;
  $$state{time_end} = $time_min;

  if ($$state{win} and $$state{lose} and $$state{wrong}) {
    $$state{lube_next} =
      time() + ((20 * $$state{wrong} * $$state{lose}) / $$state{win});
  }

  if ($$state{score}) {
    $$state{prize_chance} = int(($$state{score} / $$state{prize_target}) *
                                  $$state{prize_chance});
  }

  return $state;
}

sub pick_images {
  my $dirs  = shift;
  my $count = shift;

  my $multiplier = 3;
  my $errors = 0;

  my @pool = ();
  my @images = get_images_from_dirs($dirs);
  while ($count*$multiplier > $#images) {
    push @images,@images;
  }

  fisher_yates_shuffle(\@images);
  return @images[1 .. $count];
}

sub play_metronome_script {
  my $state = shift;

  my $command  = "aoss $$state{ctronome} -c 1 -w1 $$state{tick_file} ";
     $command .= "-w2 $$state{tock_file} -p $$state{session_script}";
  if (open my $metronome_pipe,'-|',"$command 2>/dev/null") {
    local $SIG{HUP} = sub { close $metronome_pipe; exit 0 };
    while (my $line = <$metronome_pipe>) {
      chomp $line;
      if ($line =~ /^# start/) {
        $state = read_config($$state{state_file});
        if ($$state{wrong} > int(rand($$state{score}))) {
          $$state{bonus_rank} += int(rand($$state{lose}));
          write_config($$state{state_file},$state);
        }
      }
    }
    close $metronome_pipe;
  } else {
    error_msg("Err 2: Unable to open pipe: $!",3);
  }
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
    error_msg("Err 3: Unable to open $conf_file: $!",1);
  }

  return \%options;
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

sub sec_to_human_precise {
  my $secs = shift;

  my $output = '';

  my $years;
  my $days;
  my $hours;
  my $minutes;

  if ($secs >= 365*24*24*60) {
    $years = int($secs/(365*24*60*60));
    $output .= sprintf('%iy ',$years);
    $secs -= $years * 365*24*60*60;
  }

  if ($secs >= 24*60*60 or $years > 0) {
    $days = int($secs/(24*60*60));
    $output .= sprintf('%id ',$days);
    $secs -= $days * 24*60*60;
  }

  if ($secs >= 60*60 or $years + $days > 0) {
    $hours = int($secs/(60*60));
    $output .= sprintf('%ih ',$hours);
    $secs -= $hours * 60*60;
  }

  if ($secs >= 60 or $years + $days + $hours > 0) {
    $minutes = int($secs/60);
    $output .= sprintf('%im ',$minutes);
    $secs -= $minutes * 60;
  }

  $output .= sprintf('%is',$secs);

  return $output;
}
sub sexy_slideshow {
  my $state = shift;

  my @playlist = pick_images("$$state{images_special}:$$state{images_vs}",
                              $$state{images_seed_count});
  push @playlist, pick_images($$state{images_vs},$$state{images_vs_count});
  push @playlist, pick_images($$state{images_rand},$$state{images_rand_count});

  my $images_vip_count = 0;

  if ($$state{lose} and $$state{win} and $$state{wrong}) {
    my @vips = get_images_from_dirs($$state{images_vip});
    my $max = ($#vips + 1) * ($$state{lose} + $$state{wrong} % 5);
    foreach (1 .. $max) {
      if (rand($$state{lose}) > rand($$state{win})) {
        $images_vip_count++;
      }
    }
  }

  push @playlist, pick_images($$state{images_vip},$images_vip_count);

  fisher_yates_shuffle(\@playlist);

  if (open my $playlist_fh,'>',$$state{image_playlist}) {
    foreach my $image (@playlist) {
      print $playlist_fh "$image\n";
    }
    close $playlist_fh;
  } else {
    error_msg("Err 4: Unable to open image playlist: $!",4);
  }

  my $command  = "$$state{image_viewer} --info '$$state{image_checker} '%f'' ";
     $command .= "--scale-down -Y -F --fontpath '$ENV{HOME}/.fonts/' ";
     $command .= "-D $$state{image_delay} --font 'FiraMono-Medium/32' ";
     $command .= "-Z -f $$state{image_playlist}";

  exec "$command >/dev/null 2>&1";
}

sub toggle_bool {
  my $value = shift;
  if ($value) {
    return 0;
  }
  return 1;
}

sub twitters {
  my $state   = shift;
  my $message = shift;

  my $twitter = Net::Twitter->new(
    traits              => [qw/API::RESTv1_1/],
    consumer_key        => "$$state{twitter_consumer_key}",
    consumer_secret     => "$$state{twitter_consumer_secret}",
    access_token        => "$$state{twitter_access_token}",
    access_token_secret => "$$state{twitter_access_token_secret}",
  );

  my $result = $twitter->update($message);
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
    error_msg("Err 5: Unable to open $config_file: $!",2);
  }

  return 1;
}

1;
