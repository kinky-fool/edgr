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
                    load_user
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

sub get_history {
  my $session       = shift;
  my $history_max   = shift;

  my $too_short     = $$session{too_short};
  my $since         = time - ($$session{history} * 24 * 60 * 60);

  my $dbh = db_connect($$session{database});
  my $user = $$session{user};

  my $sql = qq{
select * from sessions where user = ? and
length > ? and finished > ? order by finished desc limit ?
};
  my $sth = $dbh->prepare($sql);
  $sth->execute($user, $too_short, $since, $history_max);

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


  $$session{goal} = $$session{mean};

  if ($$session{goal} > $$session{goal_max}) {
    $$session{goal} = $$session{goal_max};
  }

  if ($$session{goal} < $$session{goal_min}) {
    $$session{goal} = $$session{goal_min};
  }

  $$session{min_safe} = $$session{goal} - $$session{goal_under};
  $$session{max_safe} = $$session{goal} + $$session{goal_over};

  $$session{time_max} = $$session{max_safe} + 300;
  $$session{duration} = 0;

  $$session{bpm_cur} = $$session{bpm_min};

  $$session{direction} = 1;

  $$session{lube_next} = next_lube($session);

  $$session{liquid_silk} = 0;
  $$session{lubed} = 0;
  $$session{prized} = -1;
  if ($$session{prize_enabled}) {
    $$session{prized} = 0;
  }

  # What ratio of recent past failures were due to being over-long
  # determines the chance for a "prize"
  #$$session{prize_chance} *= get_long_fail_ratio($session);

  # What ratio of recent sessions were successful determines a saving throw
  #$$session{disarm_chance} *= get_success_ratio($session);

  #if ($$session{prize_armed} and $$session{prize_chance} > rand(100)) {
  #  $$session{liquid_silk} = 1;
  #  if ($$session{disarm_chance} > rand(100)) {
  #    # Disable the 'prize' but keep up appearances by leaving liquid silk
  #    $$session{prize_armed} = 0;
  #    if (80 > int(100)) {
  #      $$session{liquid_silk} = 0;
  #    }
  #  }

  #  if ($$session{liquid_silk} > 0 and $$session{prize_aware}) {
  #    printf "You won the prize! Get the appropriate lubes handy.\n";
  #    printf "< Press Enter to Resume >";
  #    my $input = <STDIN>;
  #  }
  #}

  return $session;
}

sub load_user {
  my $settings = shift;

  my $dbh = db_connect($$settings{database});
  my $sql = qq{ select * from users where user = ? };
  my $sth = $dbh->prepare($sql);

  $sth->execute($$settings{user});

  my $user = $sth->fetchrow_hashref;

  $sth->finish;
  $dbh->disconnect;

  foreach my $key (keys %$user) {
    $$settings{$key} = $$user{$key};
  }
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

sub next_lube {
  my $session = shift;

  my $safe = $$session{goal} - $$session{goal_under};
  my $roll = int(rand(6));
  my $base = 2;
  if ($$session{liquid_silk}) {
    $base = 4;
  }
  $$session{lube_break} = $safe / ($base + 1);
  if ($roll == 0) {
    $$session{lube_break} = $safe / $base;
  } elsif ($roll > 3) {
    $$session{lube_break} = $safe / ($base + 2);
  }

  return $$session{duration} + fuzzy($$session{lube_break},1);
}

sub score_sessions {
  my $session = shift;
  my $count   = shift;

  if ($count > 1) {
    my $pass    = 0;
    my $history = get_history($session,$count);
    my $owed = $$session{sessions_owed};
    my $next_by = 0;
    foreach my $key (reverse sort keys %$history) {
      my $sess = $$history{$key};

      my $start = $$sess{finished} - $$sess{length};
      if ($start > $next_by) {
        $owed = $$session{sessions_owed};
      }
      $owed--;
      $next_by = $$sess{finished} + $$session{session_maxbreak};

      if ($$sess{length} >= $$sess{min_safe} and
          $$sess{length} <= $$sess{max_safe}) {
        $pass++;
      }
    }
    if ($owed > 0) {
      printf "Only %s session%s remaining...\n", $owed, $owed == 1 ? '' : 's';
      return;
    } else {
      my $percent = $pass / $count * 100;
      if ($percent > $$session{owe_percent}) {
        reset_owed($session);
        printf "Passed: %s    Failed: %s\n", $pass, $count - $pass;
      } else {
        printf "Failed; Scored too low\n";
      }
      return;
    }
  } else {
    my $history = get_history($session,1);
    foreach my $key (keys %$history) {
      my $sess = $$history{$key};
      if ($$sess{length} >= $$sess{min_safe} and
          $$sess{length} <= $$sess{max_safe}) {
        printf "Session Passed!\n";
      } else {
        printf "Session Failed!\n";
      }
    }
  }
}

sub reset_owed {
  my $session = shift;

  my $dbh = db_connect($$session{database});

  my $sql = qq{ update users set sessions_owed = default_owed where user = ? };
  my $sth = $dbh->prepare($sql);

  $sth->execute($$session{user});
  $sth->finish;
  $dbh->disconnect;

  return;
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

  my $result = $number;
  my $granularity = 1000;

  for my $i (1 .. $number * $granularity) {
    if (int(rand(rand(6)))) {
      $result += 1 / $granularity;
    } else {
      $result -= 1 / $granularity;
    }
  }

  return $result;
}
sub maybe_add_command {
  my $session = shift;

  my $command = undef;

  if ($$session{duration} > $$session{lube_next}) {

    if ($$session{lube_chance} > rand(100)) {
      $command = 'Use lube';
      $$session{lube_next} = next_lube($session);

      if ($$session{liquid_silk}) {
        $command = 'Use Liquid Silk';
        if ($$session{prize_armed} and $$session{lubed}) {
          if ($$session{prize_apply_chance} > rand(100)) {
            $$session{prized}++;
          }

          if ($$session{prized} > 0) {
            if ($$session{prize_apply_chance} * 2 > rand(100)) {
              $command = 'Use Liquid Fire';
            }
          }

          if ($$session{prized} > 1) {
            if ($$session{prize_apply_chance} > rand(100)) {
              $command = 'Use Icy Hot';
            }
          }
        }
      }

      $$session{lubed}++;
    }
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

  up_by_steps($session);
}


sub save_session {
  my $session = shift;

  my $user      = $$session{user};
  my $finished  = time;
  my $length    = $$session{endured};
  my $min_safe  = $$session{min_safe};
  my $max_safe  = $$session{max_safe};
  my $goal      = $$session{goal};
  my $mean      = $$session{mean};
  my $stddev    = $$session{stddev};
  my $prized    = $$session{prized};

  my $dbh = db_connect($$session{database});
  my $sql  = qq{ insert into sessions ( user, finished, length,
                                        min_safe, max_safe, goal,
                                        mean, stddev, prized)
                  values (?,?,?,?,?,?,?,?,?)};
  my $sth = $dbh->prepare($sql);

  $sth->execute($user, $finished, $length, $min_safe, $max_safe, $goal,
                $mean, $stddev, $prized);

  $sth->finish;
  $dbh->disconnect;
  return;
}
