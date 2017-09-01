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

sub get_long_fail_ratio {
  my $session = shift;

  my $dbh = db_connect($$session{database});
  my $sql = qq{
select count(*) from sessions where user = ? and
length / goal > ? / 100 and
date between datetime('now', ?) and datetime('now', 'localtime')
order by date desc limit ?
};
  my $sth = $dbh->prepare($sql);
  $sth->execute($$session{user}, $$session{max_pct},
                $$session{past_time}, $$session{past_sessions});
  my ($fails) = $sth->fetchrow_array;
  $sth->finish;

  $sql = qq{
select count(*) from sessions where user = ? and
date between datetime('now', ?) and datetime('now', 'localtime')
order by date desc limit ?
};
  $sth = $dbh->prepare($sql);
  $sth->execute($$session{user},$$session{past_time},$$session{past_sessions});
  my ($total) = $sth->fetchrow_array;
  $sth->finish;
  $dbh->disconnect;

  if ($total > 0) {
    return $fails / $total;
  } else {
    return 0;
  }
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

  $$session{goal} = $$session{mean};

  if ($$session{goal} > $$session{goal_max}) {
    $$session{goal} = $$session{goal_max};
  }

  if ($$session{goal} < $$session{goal_min}) {
    $$session{goal} = $$session{goal_min};
  }

  $$session{goal_radius} = int($$session{goal} / 10) + 1;
  $$session{time_max} = $$session{goal} * 1.5;

  my $range = abs($$session{bpm_max} - $$session{bpm_min});

  $$session{bpm_cur} = int(rand($range * 2 / 5)) + $$session{bpm_min};

  $$session{direction} = 1;

  $$session{lube_next} = $$session{lube_break};

  $$session{prize_armed} = $$session{prize_enabled};
  $$session{liquid_silk} = 0;
  $$session{lubed} = 0;
  $$session{prized} = 0;

  my $fail_ratio = get_long_fail_ratio($session);
  $$session{prize_chance} += $$session{prize_boost} * $fail_ratio;

  if ($$session{prize_armed} and $$session{prize_chance} > rand(100)) {
    $$session{liquid_silk} = 1;
    if ($$session{disarm_chance} > rand(100)) {
      $$session{prize_armed} = 0;
    }
  }

  return $session;
}

sub maybe_add_command {
  my $session = shift;

  my $command = undef;

  my $prize_on = 0;

  if ($$session{duration} > $$session{lube_next}) {

    if ($$session{lube_chance} > rand(100)) {
      $command = 'Use lube';
      $$session{lube_next} = $$session{duration} + $$session{lube_break};

      if ($$session{liquid_silk}) {
        $command = 'Use Liquid Silk';
        $$session{lube_next} = $$session{duration} + $$session{prize_break};
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
          for (0 .. (int(rand(3)) * 3) + 3) {
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

  my $percent = abs($$session{bpm_cur} - $min) / abs($max - $min);

  # Reverse percent pace is decreasing
  if ($direction < 0) {
    $percent = 1 - $percent;
  }

  return (($$session{max_spb} - $$session{min_spb}) * $percent)
          + $$session{min_spb};
}

sub change_tempo {
  my $session = shift;
  my $pct_new = shift;

  my ($min,$max) = tempo_limits($session);
  my $bpm_new = int(abs($max - $min) * $pct_new) + $min;

  my $direction = 1;
  if ($$session{bpm_cur} > $bpm_new) {
    $direction = -1;
  }

  my $bpm_delta = abs($$session{bpm_cur} - $bpm_new);

  # Carry-over beats, to support 0.5 beats per bpm, etc.
  my $beats = 0;

  while ($bpm_delta > 0) {
    my $seconds = seconds_per_bpm($session,$direction);

    $beats += $$session{bpm_cur} * $seconds / 60;

    if (int($beats) > 0) {
      $$session{beats} = join('#',(split(/#/,$$session{beats}),
                          sprintf('%g:%g', int($beats), $$session{bpm_cur})));
      $$session{duration} += int($beats) * 60 / $$session{bpm_cur};
      $beats -= int($beats);
    }

    # Change pace
    $$session{bpm_cur} += $direction;
    $bpm_delta--;
  }
}

sub tempo_limits {
  my $session = shift;

  my $min = $$session{bpm_min};
  my $max = $$session{bpm_max};

  # Handle maximum pace increases
  if ($$session{duration} > ($$session{goal} / 2)) {
    $max += $$session{bpm_max_inc};
  }

  if ($$session{duration} > ($$session{goal} - $$session{goal_radius})) {
    $max += $$session{bpm_max_inc};
  }

  # Handle minimum pace increases
  if ($$session{duration} > ($$session{goal} / 4)) {
    $min += $$session{bpm_min_inc};
  }

  if ($$session{duration} > ($$session{goal} * 3 / 4)) {
    $min += $$session{bpm_min_inc};
  }

  if ($$session{duration} > ($$session{goal} + $$session{goal_radius})) {
    $min += $$session{bpm_min_inc};
  }

  if ($$session{bpm_cur} > $min and $$session{bpm_cur} > $$session{bpm_min}) {
    $min = $$session{bpm_cur};
  }

  return ($min,$max);
}

sub tempo_stats {
  my $session = shift;

  my ($min,$max)  = tempo_limits($session);

  my $range       = abs($max - $min);
  # abs() is meant to handle situation where bpm_cur < min due to recalc
  my $pct         = abs($$session{bpm_cur} - $min) / $range;

  my $from_half   = abs($pct - 0.5);

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

sub make_beats {
  my $session = shift;

  my ($max,$min) = tempo_limits($session);
  my ($range,$pct,$from_half) = tempo_stats($session);

  my $flow = -1;
  if ($pct > 0.5) {
    $flow = 1;
  }

  my $direction = $$session{direction};

  # Go against the flow more often (but not 100%) as tempo approaches limits
  if ($from_half / 0.5 > rand(1.5)) {
    $$session{direction} = $flow * -1;
  }

  if ($pct > 0.8 and $pct <= 0.9 and $$session{direction} > 0 and
      !int(rand(6))) {
    steady_beats($session, rand(15) + 5);
    for (0 .. int(rand(4)) + 1) {
      # Down
      my $pct_new = rand(0.3) + 0.4; 
      change_tempo($session, $pct_new);
      steady_beats($session, rand(3) + 1);

      # Up
      my $pct_new = 1 - rand(0.15);
      change_tempo($session, $pct_new);
      steady_beats($session, rand(15) + 5);
    }

    # Prevent doing steady_beats() again
    $$session{direction}  = -1;
    $direction            = -1;
  }

  ($range,$pct,$from_half) = tempo_stats($session);

  # Pause for a bit when changing direction
  if ($direction != $$session{direction}) {
    my $steady_secs = 15 * ($from_half / 0.5);
    steady_beats($session, $steady_secs + 1);
  }

  my $min_jump = 0.05;
  my $max_jump = $pct;
  if ($$session{direction} > 0) {
    $max_jump = 1 - $pct;
  }

  if (int(rand(6))) {
    $max_jump = $max_jump / 2;
  }

  my $jump = (abs($max_jump - $min_jump) * $from_half / 0.5) + $min_jump;
  my $pct_new = abs($pct + ($jump * $$session{direction}));
  change_tempo($session, $pct_new);
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
