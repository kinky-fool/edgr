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
                    read_config
                    init_session
                    make_beats
                    write_script
                    play_script
                    save_session
                    twitters
                );
@EXPORT_OK    = @EXPORT;

sub db_connect {
  my $dbf = shift;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbf","","") ||
    error("could not connect to database: $!",1);
  return $dbh;
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
  my $session = shift;

  my $dbh = db_connect($$session{database});
  my $sql = qq{
select * from sessions where user = ? and
date between datetime('now', ?) and datetime('now', 'localtime')
order by date desc limit ?
};

  # Prepare the SQL statement
  my $sth = $dbh->prepare($sql);

  # Execute the SQL statement
  $sth->execute($$session{user},
                $$session{past_time},
                $$session{past_sessions});

  # Fetch any results into a hashref
  my $history = $sth->fetchall_hashref('session_id');

  # Clean up
  $sth->finish;
  $dbh->disconnect;

  return $history;
}

sub get_times {
  my $session = shift;

  my $dbh = db_connect($$session{database});
  my $sql = qq{
select length from sessions where user = ? and
length / goal > ? / 100 and
date between datetime('now', ?) and datetime('now', 'localtime')
order by date desc limit ?
  };
  my $sth = $dbh->prepare($sql);
  $sth->execute($$session{user},$$session{min_pct},
                $$session{past_time},$$session{past_sessions});
  my @times = ();
  while (my ($time) = $sth->fetchrow_array) {
    push @times, $time;
  }
  $sth->finish;
  $dbh->disconnect;

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
  my $conf = shift;

  my $session = $conf;
  my $dbh = db_connect($$session{database});

  my $sql = 'select * from users where user = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($$session{user});
  my $options = $sth->fetchrow_hashref;

  $sth->finish;
  $dbh->disconnect;

  foreach my $key (keys %$options) {
    $$session{$key} = $$options{$key};
  }

  $$session{duration} = 0;

  my @times = get_times($session);
  if (scalar(@times) >= $$session{min_sessions}) {
    $$session{mean} = mean(@times);
    $$session{stddev} = stddev(@times);
  } else {
    $$session{mean} = $$session{default_mean};
    $$session{stddev} = $$session{default_stddev};
  }

  #printf "Resetting to default_mean code in place\n";
  # Reset things
  #$$session{mean} = fuzzy($$session{default_mean},1);
  #$$session{stddev} = $$session{default_stddev};

  $$session{goal} = $$session{mean};

  if ($$session{goal} > $$session{goal_max}) {
    $$session{goal} = $$session{goal_max};
  }

  if ($$session{goal} < $$session{goal_min}) {
    $$session{goal} = $$session{goal_min};
  }

  $$session{time_max} = $$session{goal} + fuzzy(8*60,1);

  $$session{bpm_cur} = $$session{bpm_min};

  $$session{direction} = 1;

  $$session{lube_next} = next_lube($session);

  $$session{liquid_silk} = 0;
  $$session{lubed} = 0;
  $$session{prized} = 0;

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

sub next_lube {
  my $session = shift;

  my $safe = $$session{goal} - $$session{goal_under};
  my $roll = int(rand(6));
  $$session{lube_break} = $safe / 3;
  if ($roll == 0) {
    $$session{lube_break} = $safe / 2;
  } elsif ($roll > 3) {
    $$session{lube_break} = $safe / 4;
  }

  return $$session{duration} + fuzzy($$session{lube_break},1);
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

sub maybe_add_command {
  my $session = shift;

  my $command = undef;

  my $prize_on = 0;

  if (defined $$session{max_lubes} and $$session{max_lubes} >= 0) {
    if ($$session{lubed} >= $$session{max_lubes}) {
      return undef;
    }
  }

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

  my ($min,$max) = tempo_limits($session);

  my $percent = 1;
  if ($max != $min) {
    $percent = abs($$session{bpm_cur} - $min) / abs($max - $min);
  }

  # Reverse percent pace is decreasing
  if ($direction < 0) {
    $percent = 1 - $percent;
  }

  return (($$session{max_spb} - $$session{min_spb}) * $percent)
          + $$session{min_spb};
}

sub change_tempo {
  my $session = shift;
  my $bpm_new = shift;
  my $rate    = shift || 1;

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

sub tempo_limits {
  my $session = shift;

  my $min = $$session{bpm_min};
  my $max = $$session{bpm_max};

  # Handle maximum pace increases
  if ($$session{duration} > ($$session{time_max} / 4)) {
    $max += $$session{bpm_max_inc};
  }

  if ($$session{duration} > ($$session{goal} - $$session{goal_under})) {
    $max += $$session{bpm_max_inc};
  }

  # Handle minimum pace increases
  if ($$session{duration} > ($$session{time_max} / 3)) {
    $min += $$session{bpm_min_inc};
  }

  if ($$session{duration} > ($$session{time_max} * 2 / 3)) {
    $min += $$session{bpm_min_inc};
  }

  if ($$session{duration} > ($$session{time_max} + $$session{goal_over})) {
    $min += $$session{bpm_min_inc};
  }

  if ($$session{bpm_cur} < $min and $$session{bpm_cur} > $$session{bpm_min}) {
    $min = $$session{bpm_cur};
  }

  return ($min,$max);
}

sub tempo_stats {
  my $session = shift;

  my ($min,$max)  = tempo_limits($session);

  my $range = abs($max - $min);
  my $pct = 0;
  if ($range > 0) {
    # abs() is meant to handle situation where bpm_cur < min
   $pct = abs($$session{bpm_cur} - $min) / $range;
  }

  my $from_half = abs($pct - 0.5);

  return ($range,$pct,$from_half);
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

sub get_max_bpm {
  my $session = shift;

  my $range = abs($$session{bpm_max} - $$session{bpm_min});

  my $percent = $$session{duration} / ($$session{goal} - $$session{goal_under});

  my $max_bpm = $range / 5;

  if ($percent >= 0.10) {
    $max_bpm = $range * 2 / 5;
  }

  if ($percent >= 0.30) {
    $max_bpm = $range * 3 / 5;
  }

  if ($percent >= 0.60) {
    $max_bpm = $range * 4 / 5;
  }

  if ($percent >= 1) {
    $max_bpm = $range;
  }

  if ($$session{duration} => $$session{goal} + $$session{goal_over}) {
    $max_bpm = $range / 5;
  }

  $max_bpm += $$session{bpm_min};

  return $max_bpm;
}

sub up_and_down {
  my $session = shift;

  my $max = get_max_bpm($session);

  my $step_size = 20;

  my $bpm = $$session{bpm_cur};
  my $seconds = 1;

  while ($$session{bpm_max} > $$session{bpm_cur}) {
    change_tempo($session, $$session{bpm_min}, 0.5);
    steady_beats($session, 1);

    $bpm += $step_size;
    change_tempo($session, $bpm, 0.5);
    steady_beats($session, $seconds + (rand($seconds) * 2));
    $seconds++;
  }

  for (0 .. int(rand(3)) + 1) {
    change_tempo($session, $$session{bpm_min}, 0.4);
    steady_beats($session, int(rand(10)));
    change_tempo($session, $bpm, 0.5);
    steady_beats($session, $seconds + (rand($seconds) * 2));
  }

  while ($$session{bpm_cur} > $$session{bpm_min}) {
    change_tempo($session, $$session{bpm_min}, 0.5);
    steady_beats($session, 1);

    $bpm -= $step_size;
    change_tempo($session, $bpm, 0.5);
    steady_beats($session, $seconds + (rand($seconds) * 2));
    $seconds--;
  }
}

sub make_beats {
  my $session = shift;

  up_and_down($session);
}


sub save_session {
  my $session = shift;

  my $dbh = db_connect($$session{database});
  my $sql  = qq{insert into sessions (user,length,goal,mean,prize_enabled)
                  values (?,?,?,?,?)};
  my $sth = $dbh->prepare($sql);

  $sth->execute($$session{user},$$session{endured},$$session{goal},
                  $$session{mean},$$session{prize_enabled});
  $sth->finish;
  $dbh->disconnect;
  return;
}
