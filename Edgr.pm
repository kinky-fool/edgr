package Edgr;

use strict;
use DBI;
use Statistics::Basic qw(:all);
use Net::Twitter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $DEBUG);

$VERSION      = 0.0.1;
$DEBUG        = 0;
@ISA          = qw(Exporter);
# Functions used in scripts
@EXPORT       = qw(
                    db_connect
                    deny_play
                    get_history
                    init_session
                    read_settings
                    make_beats
                    play_script
                    read_config
                    save_session
                    score_sessions
                    sec_to_human
                    sec_to_human_precise
                    twitters
                    write_script
                );
@EXPORT_OK    = @EXPORT;

sub db_connect {
  my $dbf = shift;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbf","","") ||
    error("could not connect to database: $!",1);
  return $dbh;
}

sub deny_play {
  my $settings = shift;

  my $most_recent = time - $$settings{session_break};
  my $history = get_history($settings,$$settings{history_max});

  foreach my $key (keys %$history) {
    my $sess = $$history{$key};
    if ($$sess{finished} > $most_recent) {
      my $to_wait = $$sess{finished} - $most_recent;
      printf "Wait %s longer\n", sec_to_human_precise($to_wait);
      exit;
    }
  }
}

sub error {
  my $message = shift;
  my $rv      = shift;

  printf STDERR "Error: %s\n",$message;
  if ($rv >= 0) {
    exit $rv
  }
}
sub get_unscored {
  my $session       = shift;

  my $too_short     = $$session{too_short};

  my $dbh = db_connect($$session{database});
  my $user_id = $$session{user_id};

  my $sql = qq{
select * from sessions where user_id = ? and
length > ? and scored = 0 order by finished desc
};
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id, $too_short);

  # Fetch any results into a hashref
  my $unscored = $sth->fetchall_hashref('session_id');

  # Clean up
  $sth->finish;
  $dbh->disconnect;

  return $unscored;
}

sub get_history {
  my $session       = shift;
  my $history_max   = shift;

  my $too_short     = $$session{too_short};
  my $since         = time - ($$session{history} * 24 * 60 * 60);

  my $dbh = db_connect($$session{database});
  my $user_id = $$session{user_id};

  my $sql = qq{
select * from sessions where user_id = ? and
length > ? and finished > ? order by finished desc limit ?
};
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id, $too_short, $since, $history_max);

  # Fetch any results into a hashref
  my $history = $sth->fetchall_hashref('session_id');

  # Clean up
  $sth->finish;
  $dbh->disconnect;

  return $history;
}

sub get_times {
  my $session = shift;

  my $history = get_history($session,$$session{history_max});
  my @times   = ();

  foreach my $key (keys %$history) {
    my $sess = $$history{$key};
    push(@times,$$sess{length});
  }

  return @times;
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
    error("Err 3: Unable to open $conf_file: $!",1);
  }

  return \%options;
}

sub init_session {
  my $settings  = shift;

  my $session   = $settings;

  my @times = get_times($session);

  if (scalar(@times) >= $$session{min_sessions}) {
    $$session{mean} = mean(@times);
    # Remove commas added by mean()
    $$session{mean} =~ s/,//g;
    $$session{stddev} = stddev(@times);
  } else {
    $$session{mean} = $$session{default_mean};
    $$session{stddev} = $$session{default_stddev};
  }

  if ($$session{goal} == -1) {
    $$session{goal} = $$session{mean};
  }

  if ($$session{goal} > $$session{goal_max}) {
    $$session{goal} = $$session{goal_max};
  }

  if ($$session{goal} < $$session{goal_min}) {
    $$session{goal} = $$session{goal_min};
  }

  $$session{min_safe} = $$session{goal} - $$session{goal_pre};
  $$session{max_safe} = $$session{min_safe} + $$session{goal_window};

  $$session{too_slow_next} = $$session{max_safe} + $$session{too_slow_start};
  $$session{too_slow} = $$session{too_slow_next};

  $$session{time_max} = $$session{max_safe} + 300;
  $$session{duration} = 0;

  $$session{bpm_cur} = $$session{bpm_min};

  $$session{direction} = 1;

  $$session{lube_next} = lube_next($session);

  $$session{lubed} = 0;
  $$session{prized} = -1;

  if ($$session{prize_enabled}) {
    $$session{prized} = 0;
    arm_prize($session);
  }


  return $session;
}

sub arm_prize {
  my $session = shift;

  my $unscored = get_unscored($session);

  my $too_long  = 0;
  my $pass      = 0;
  my $total     = 0;

  foreach my $sesh_id (keys %$unscored) {
    my $sesh = $$unscored{$sesh_id};

    if ($$sesh{length} > $$sesh{max_safe}) {
      $too_long++;
    }

    if ($$sesh{length} >= $$sesh{min_safe} and
        $$sesh{length} <= $$sesh{max_safe}) {
      $pass++;
    }

    $total++;
  }

  for (0 .. $too_long) {

    if ($$session{prize_arm} > rand(100)) {
      $$session{prize_armed}  = 1;
      $$session{prize_fake}   = 1;
    }

    if ($$session{prize_armed} and $pass > 0) {
      $pass--;
      if ($$session{prize_disarm} > rand(100)) {
        $$session{prize_armed} = 0;
      }
    }
  }

  if ($$session{prize_armed}) {
    $$session{prized} = 1;
  }

  if ($$session{prize_fake}) {
    printf "   You won the prize!\n";
    printf "   Get Icy Hot Handy.\n";
    printf "< Press Enter to Resume >";
    my $input = <STDIN>;
  }
}

sub read_settings {
  my $settings = shift;

  my $dbh = db_connect($$settings{database});
  my $sql = qq{ select user_id from users where username = ? };
  my $sth = $dbh->prepare($sql);

  $sth->execute($$settings{user});

  my ($user_id) = $sth->fetchrow_array;

  $$settings{user_id} = $user_id;

  $sql = qq{ select key, value from settings where user_id = ? };
  $sth = $dbh->prepare($sql);
  $sth->execute($user_id);

  while (my $row = $sth->fetchrow_hashref) {
    $$settings{$$row{key}} = $$row{value};
  }

  $sth->finish;
  $dbh->disconnect;
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

sub lube_next {
  my $session = shift;

  my $range = abs($$session{lube_break_max} - $$session{lube_break_min});

  my $delay = $$session{lube_min} + go_high($range / 2);

  if ($$session{prize_fake}) {
    $delay = $$session{lube_min} + fuzzy($range / 2, 1);
  }

  if ($$session{prize_fake} and $$session{lubed} == 0) {
    $delay = $delay * 180 / 100;
    if (int(rand(3))) {
      $$session{prize_fake} = 0;
    }
  }

  if ($$session{prize_armed} and $$session{lubed} == 1) {
    $delay = $delay * 40 / 100;
  }

  if ($$session{prize_armed} and $$session{lubed} > 1) {
    $delay = $delay * 120 / 100;
  }

  return $$session{duration} + $delay;
}

sub score_sessions {
  my $session = shift;

  my $streak      = 0;
  my $max_streak  = 0;
  my $pass        = 0;
  my $fail        = 0;
  my $next_by     = time;

  # re-fresh settings from the database
  read_settings($session);

  # First score the current session
  if ($$session{passes_per_slow}) {
    if ($$session{length} >= $$session{too_slow}) {
      my $over_by = $$session{length} - $$session{too_slow};
      my $count = int($over_by / $$session{too_slow_interval}) + 1;
      $$session{owed_passes} += $$session{passes_per_slow} * $count;
    }
  }

  if ($$session{passes_per_fail} > 0) {
    if ($$session{min_safe} > $$session{length} or
        $$session{length} > $$session{max_safe}) {
       $$session{owed_passes} += $$session{passes_per_fail};
    }
  }

  # Then check the unscored sessions, to see if a challenge has been passed
  my $unscored = get_unscored($session);

  foreach my $id (keys %$unscored) {
    my $sess = $$unscored{$id};

    my $start = $$sess{finished} - $$sess{length};

    if ($start > $next_by) {
      $streak = 0;
    }

    $streak++;
    if ($streak > $max_streak) {
      $max_streak = $streak;
    }
    $next_by = $$sess{finished} + $$session{session_maxbreak};

    if ($$sess{length} >= $$sess{min_safe} and
        $$sess{length} <= $$sess{max_safe}) {
      $pass++;
    } else {
      $fail++;
    }
  }

  # Flag for passing any set challenges (no challege = pass)
  my $passed = 1;

  # Fail if player hasn't achieved a required streak
  if ($$session{owed_streak} > $max_streak) {
    $passed = 0;
  }

  # Fail if player has not passed the a required number of sessions
  if ($$session{owed_passes} > $pass) {
    $passed = 0;
  }

  # Fail if player has not achieved the required pass/fail percent
  my $percent = ($pass / ($pass + $fail)) * 100;
  if ($$session{owed_percent} > $percent) {
    $passed = 0;
  }

  if ($$session{prized} == 1) {
    printf "You got very lucky. Prize was armed.\n";
  }

  if ($passed) {
    if ($$session{passes_per_draw} > 0) {
      $$session{owed_passes_default} += $$session{passes_per_draw};
    }

    $$session{owed_streak} = $$session{owed_streak_default};
    $$session{owed_passes} = $$session{owed_passes_default};
    $$session{owed_percent} = $$session{owed_percent_default};

    if ($$session{passes_per_fail} > 0) {
      $$session{owed_passes} += $$session{passes_per_fail} * $fail;
    }

    my @keys = qw( owed_streak owed_passes owed_percent owed_passes_default );
    save_settings($session,\@keys);

    if ($$session{verbose}) {
      printf "% Passes - %s Fails - Draw a bead!\n", $pass, $fail;
      if ($$session{verbose} > 1) {
        printf "%s pass%s required for next draw.\n",
                  $$session{owed_passes},
                  ($$session{owed_passes} == 1)?'':'es';
      }
    } else {
      printf "Draw a bead!\n"
    }

    mark_scored($session);
  } else {
    printf "More sessions required.\n";
  }
}

sub mark_scored {
  my $session     = shift;

  my $dbh = db_connect($$session{database});

  my $sql = qq{ update sessions set scored = 1 where user_id = ? };
  my $sth = $dbh->prepare($sql);
  $sth->execute($$session{user_id});

  $sth->finish;
  $dbh->disconnect;
}

sub fuzzy {
  my $number  = shift;
  my $degree  = shift;

  return $number if ($degree <= 0);

  for (1 .. int($degree)) {
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

sub go_high {
  my $number  = shift;

  for (1 .. 3) {
    my $result = $number;

    my $step = 1;

    if (!int(rand(3))) {
      $step = -1;
    }

    for (1 .. int($number)) {
      if (int(rand(7)) > 2) {
        $result += $step;
      } else {
        $result -= $step;
      }
    }
    $number = $result;
  }

  return $number;
}

sub maybe_add_command {
  my $session = shift;

  my $command = undef;

  if ($$session{duration} > $$session{lube_next}) {

    $command = 'Use lube';
    $$session{lube_next} = lube_next($session);

    if ($$session{prize_fake} or $$session{prize_armed}) {
      $command = 'Use "Icy-safe" lube.';
      if ($$session{prize_armed} and $$session{lubed}) {
        if ($$session{prize_apply} > rand(100)) {
          $$session{prized}++;
          $command = 'Use Icy Hot.';
        }
      }
    }

    $$session{lubed}++;
  }

  if ($command) {
    return $command;
  }

  return undef;
}

sub write_script {
  my $session = shift;

  # Reset for interleaving the commands
  $$session{duration} = 0;
  if (open my $script_fh,'>',$$session{script_file}) {
    foreach my $beat (split(/#/,$$session{beats})) {
      my ($count,$bpm) = split(/:/,$beat);
      while ($count > 0) {

        if ($$session{duration} > $$session{min_safe} and
            $$session{tell_pass}) {
          printf $script_fh "# Min safe reached.\n";
          $$session{tell_pass} = 0;
        }
        if ($$session{duration} > $$session{max_safe} and
            $$session{tell_fail}) {
          printf $script_fh "# Max safe reached.\n";
          $$session{tell_fail} = 0;
        }

        if ($$session{duration} > $$session{too_slow_next} and
            $$session{tell_too_slow}) {
          printf $script_fh "# Too slow...\n";
          $$session{too_slow_next} =
              $$session{too_slow_next} + $$session{too_slow_interval};
        }

        if (my $command = maybe_add_command($session)) {
          printf $script_fh "# ...\n";
          if (int(rand(5)) < 3) {
            printf $script_fh "# ...\n";
          }
          printf $script_fh "# %s\n", $command;
        }
        $$session{duration} += 60  / $bpm;
        printf $script_fh "1 %g/4 2/8\n", $bpm;
        $count--;
      }
    }
    close $script_fh;
  } else {
    error("Unable to open script ($$session{script_file}): $!",1);
  }
}

sub play_script {
  my $session = shift;

  my $start = time();

  my $command  = "aoss $$session{ctronome} -c 1 -w1 $$session{tick_file} ";
     $command .= "-w2 $$session{tock_file} -p $$session{script_file}";
  system($command);
  $$session{endured} = abs($start - time());
}

sub steady_beats {
  my $session = shift;
  my $seconds = shift;

  my $beats = $$session{bpm_cur} * $seconds / 60;

  $$session{beats} = join('#',(split(/#/,$$session{beats}),
                                  "$beats:$$session{bpm_cur}"));
  $$session{duration} += int($beats) * 60 / $$session{bpm_cur};
}

sub seconds_per_bpm {
  # Calculate the number of seconds a specific BPM should be used
  my ($session,$direction) = @_;

  my $min_spb = 0.5;
  my $max_spb = 1.0;
  my $bpm_cur = $$session{bpm_cur};
  my $bpm_min = $$session{bpm_min};
  my $bpm_max = $$session{bpm_max};

  my $percent = abs($bpm_cur - $bpm_min) / abs($bpm_max - $bpm_min);

  # Reverse percent pace is decreasing
  if ($direction < 0) {
    $percent = 1 - $percent;
  }

  return (($max_spb - $min_spb) * $percent) + $min_spb;
}

sub change_tempo {
  my $session = shift;
  my $bpm_new = shift;
  my $rate    = shift;

  my $direction = 1;
  if ($$session{bpm_cur} > $bpm_new) {
    $direction = -1;
  }

  my $bpm_delta = abs($$session{bpm_cur} - $bpm_new);

  # Carry-over beats, to support 0.5 beats per bpm, etc.
  my $beats = 0;

  while ($bpm_delta > 0) {
    my $seconds = seconds_per_bpm($session,$direction) * $rate;

    $beats += $$session{bpm_cur} * $seconds / 60;

    if (int($beats) > 0) {
      $$session{beats} = join('#',(split(/#/,$$session{beats}),
                          sprintf('%g:%g', int($beats), $$session{bpm_cur})));
      $$session{duration} += int($beats) * 60 / $$session{bpm_cur};
      $beats -= int($beats);
    }

    $$session{bpm_cur} += $direction;

    $bpm_delta--;
  }
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

sub up_and_down {
  my $session = shift;

  my $steps = int(rand(5)) + 6;

  my $bpm = $$session{bpm_cur};
  my $seconds = 1;

  for my $step (0 .. $steps) {
    change_tempo($session, $$session{bpm_min}, 0.5);
    steady_beats($session, fuzzy(10,2));
    for (0 .. $step) {
      my $diff = $$session{bpm_max} - $$session{bpm_cur};
      my $new_bpm = $$session{bpm_cur} + ($diff / 3);
      my $pct = ($$session{bpm_cur} - $$session{bpm_min}) /
                ($$session{bpm_max} - $$session{bpm_min});
      change_tempo($session, $new_bpm, 0.6 + (1.9 * $pct));
      my $steady = rand($seconds) + rand($seconds) + rand($seconds) + 3;
      steady_beats($session, fuzzy($steady,2));
      $seconds++;
    }
  }

  change_tempo($session, $$session{bpm_max}, 2.5);
  my $steady = rand($seconds) + rand($seconds) + rand($seconds) + 3;
  steady_beats($session, fuzzy($steady,2));
}

sub up_to_percent {
  my $session = shift;

  change_tempo($session, $$session{bpm_min}, 0.7);
  steady_beats($session, go_high(6));

  my $range = $$session{bpm_max} - $$session{bpm_min};
  my $steady = fuzzy(25,1);
  my $percent = 25 + go_high(50);
  my $add = $range * $percent / 100;
  my $steps = int(rand(4)) + 2;
  for my $step (1 .. $steps) {
    change_tempo($session, $$session{bpm_cur} + ($add / $steps),
                  1 + go_high(2));
    steady_beats($session, go_high($steady * $step / $steps));
  }
}

sub fixed_program_one {
  my $session = shift;

  my $bpm_min = $$session{bpm_min};
  my $bpm_max = $$session{bpm_max};
  my $bpm_range = $bpm_max - $bpm_min;
  my $step_size = $bpm_range / 7;

  $$session{bpm_cur} = $bpm_min;
  steady_beats($session,15);
  change_tempo($session,$$session{bpm_cur} + $step_size,1);
  steady_beats($session,4);
  change_tempo($session,$bpm_min,0.7);
  steady_beats($session,10);
  change_tempo($session,$$session{bpm_cur} + ($step_size * 2),1.2);
  steady_beats($session,4);
  change_tempo($session,$$session{bpm_cur} + $step_size, 1);
  steady_beats($session,4);
  change_tempo($session,$bpm_min,0.5);
  steady_beats($session,10);
  change_tempo($session,$$session{bpm_cur} + ($step_size * 5), 0.9);
  steady_beats($session,10);
  change_tempo($session,$$session{bpm_cur} - ($step_size * 3), 0.6);
  steady_beats($session, 3);
  change_tempo($session,$$session{bpm_cur} + ($step_size * 4), 0.7);
  steady_beats($session, 8);
  change_tempo($session,$$session{bpm_cur} - ($step_size * 3), 0.6);
  steady_beats($session, 5);
  change_tempo($session, $$session{bpm_cur} + ($step_size * 4), 0.5);
  steady_beats($session, 10);

  for (0 .. 4) {
    change_tempo($session, $$session{bpm_cur} - ($step_size * 2), 0.5);
    change_tempo($session, $$session{bpm_cur} + $step_size, 0.8);
  }

  steady_beats($session, 10);
  change_tempo($session, $bpm_min, 1);
  steady_beats($session, 5);
  change_tempo($session, $$session{bpm_cur} + ($step_size * 4), 0.5);
  steady_beats($session, 4);
  change_tempo($session, $$session{bpm_cur} - ($step_size * 2), 1.5);
  steady_beats($session, 10);
  change_tempo($session, $$session{bpm_cur} + ($step_size * 4), 0.5);
  steady_beats($session, 4);
  change_tempo($session, $$session{bpm_cur} - ($step_size * 2), 1.5);
  steady_beats($session, 10);
  change_tempo($session, $bpm_max, 2);
  steady_beats($session, 15);
  change_tempo($session, $bpm_min + ($bpm_range / 2), 0.8);
  steady_beats($session, 4);
  change_tempo($session, $bpm_min + ($bpm_range * 2 / 3), 1.2);
  steady_beats($session, 4);
  change_tempo($session, $bpm_min + ($bpm_range / 3), 0.6);
  steady_beats($session, 4);
  change_tempo($session, $bpm_min + ($bpm_range / 2), 1.3);
  change_tempo($session, $bpm_min, 0.4);
}

sub tempo_rate_time {
  my $session = shift;
  my $tempo = shift;
  my $rate = shift;
  my $time = shift;

  change_tempo($session, $$session{bpm_cur} + $tempo, $rate);
  steady_beats($session, $time);
}

sub fixed_program_two {
  my $session = shift;

  my $bpm_min = $$session{bpm_min};
  my $bpm_max = $$session{bpm_max};
  my $bpm_range = $bpm_max - $bpm_min;
  my $steps = 6;
  my $step_size = $bpm_range / $steps;

  $$session{bpm_cur} = $bpm_min;
  steady_beats($session, 10);

  for my $loop (3 .. $steps) {
    for (1 .. $loop) {
      tempo_rate_time($session, $step_size, 0.2 + (0.1 * $loop), 5);
    }
    steady_beats($session,10);
    my $diff = ($$session{bpm_cur} - $bpm_min);
    my $step1 = $diff / 4;
    my $step2 = $diff / 3;
    my $step3 = $diff - ($step1 + $step2);
    tempo_rate_time($session, $step1 * -1, 0.6, 5 + $loop);
    tempo_rate_time($session, $step2 * -1, 0.8, 5 + $loop);
    tempo_rate_time($session, $step3 * -1, 1.2, 10 + $loop * 2);
  }
}

sub up_by_steps {
  my $session = shift;

  my $min_rate = 1;
  my $max_rate = rand(4) + 2;

  my $max_steps = 10;
  my $step_size = ($$session{bpm_max} - $$session{bpm_min}) / $max_steps;

  my $steps = 4 + int(rand($max_steps - 3));

  my $step = 0;

  change_tempo($session, $$session{bpm_min}, 0.7);

  while ($steps > $step) {
    $step++;
    my $rate = $min_rate + (($max_rate - $min_rate) / (2 ** ($steps - $step)));
    change_tempo($session, $$session{bpm_cur} + $step_size, $rate);
    steady_beats($session, go_high(10));
  }

  $max_rate = rand(4) + 2;

  while ($step > 0) {
    $step--;
    my $rate = $min_rate + (($max_rate - $min_rate) / (2 ** $step));
    change_tempo($session, $$session{bpm_cur} - $step_size, $rate);
    steady_beats($session, go_high(10));
  }
}

sub make_beats {
  my $session = shift;

  fixed_program_two($session);
}

sub save_settings {
  my $session = shift;
  my $keys    = shift;

  my $user_id = $$session{user_id};

  my $dbh = db_connect($$session{database});
  my $sql = 'insert or replace into settings (user_id, key, value)
                                              values (?, ?, ?)';
  my $sth = $dbh->prepare($sql);

  foreach my $key (@$keys) {
    my $val = $$session{$key};
    my $rv = $sth->execute($user_id, $key, $val);
    unless ($rv) {
      printf "error: unable to update %s -> %s for user_id: %s\n",
                $key, $val, $user_id;
    }
  }
  $sth->finish;
  $dbh->disconnect;
}

sub save_session {
  my $session = shift;

  my $user_id     = $$session{user_id};
  my $finished    = time;
  my $length      = $$session{endured};
  my $min_safe    = $$session{min_safe};
  my $max_safe    = $$session{max_safe};
  my $goal        = $$session{goal};
  my $goal_pre    = $$session{goal_pre};
  my $goal_window = $$session{goal_window};
  my $mean        = $$session{mean};
  my $stddev      = $$session{stddev};
  my $prized      = $$session{prized};

  my $dbh = db_connect($$session{database});
  my $sql  = qq{ insert into sessions ( user_id, finished, length,
                                        min_safe, max_safe, goal, goal_pre,
                                        goal_window, mean, stddev, prized)
                  values (?,?,?,?,?,?,?,?,?,?,?)};
  my $sth = $dbh->prepare($sql);

  $sth->execute($user_id, $finished, $length, $min_safe, $max_safe, $goal,
                $goal_pre, $goal_window, $mean, $stddev, $prized);

  $sth->finish;
  $dbh->disconnect;
  return;
}
