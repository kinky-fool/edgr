package Edgr;

use strict;
use DBI;
use Statistics::Basic qw(:all);
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $DEBUG);

$VERSION      = 0.0.1;
$DEBUG        = 0;
@ISA          = qw(Exporter);
# Functions used in scripts
@EXPORT       = qw(
                    read_config
                    init_session
                    make_beats
                    write_script
                    play_script
                    save_session
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

  return $fails / $total;
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
    error_msg("Err 3: Unable to open $conf_file: $!",1);
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
  $$session{time_max} = $$session{goal} * 3;

  my ($min,$max) = tempo_limits($session);
  $$session{bpm_cur} = $min + int(rand(($max - $min) * 2 / 5));

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

  my $beats = int($$session{bpm_cur} * ($seconds / 60));

  $$session{beats} = join('#',(split(/#/,$$session{beats}),
                                  "$beats:$$session{bpm_cur}"));
  $$session{duration} += $seconds;
}

sub change_tempo {
  my $session = shift;
  my $bpm_end = shift;

  # Carry-over beats, to support 0.5 beats per bpm, etc.
  my $beats = 0;
  my $bpm_delta = int(abs($bpm_end - $$session{bpm_cur}));

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};

  while ($bpm_delta > 0) {
    my $percent = ($$session{bpm_cur} - $$session{bpm_min}) / $bpm_range;
    if ($$session{direction} < 0) {
      $percent = 1 - $percent;
    }
    my $spb = ($$session{max_spb} - $$session{min_spb}) * $percent +
              $$session{min_spb};

    $beats += $spb * ($$session{bpm_cur} / 60);
    if (int($beats) > 0) {
      $$session{beats} = join('#',(split(/#/,$$session{beats}),
                          sprintf('%g:%g', int($beats), $$session{bpm_cur})));
      $$session{duration} += int($beats) * 60 / $$session{bpm_cur};
      $beats -= int($beats);
    }
    $$session{bpm_cur} += $$session{direction};
    $bpm_delta--;
  }
}

sub tempo_limits {
  my $session = shift;

  my $pct_complete  = $$session{duration} / $$session{goal};
  my $pct_max       = 0.75;

  # After % complete, the tempo range is open
  if ($pct_complete > $pct_max) {
    return ($$session{bpm_min},$$session{bpm_max});
  }

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  if ($bpm_range < 0) {
    $bpm_range = abs($bpm_range); # The show must go on, eh?
    printf "bpm_max less than bpm_min? config issue?\n";
  }

  my $min_buffer = $bpm_range / 4;
  my $max_buffer = $bpm_range / 2;
  $min_buffer = int($min_buffer - ($min_buffer * $pct_complete / $pct_max));
  $max_buffer = int($max_buffer - ($max_buffer * $pct_complete / $pct_max));
  return ($$session{bpm_min} + $min_buffer, $$session{bpm_max} - $max_buffer);
}

sub make_beats {
  my $session = shift;

  my ($min,$max) = tempo_limits($session);

  my $bpm_range = abs($max - $min);
  # abs() is meant to handle situation where bpm_cur < min due to recalc
  my $percent = (abs($$session{bpm_cur} - $min) / $bpm_range) * 100;

  my $from_half = abs($percent - 50);

  my $the_flow = -1;
  if ($percent > 30) {
    $the_flow = 1;
  }

  my $old_dir = $$session{direction};
  # Go with the flow, man.
  if (!int(rand(4))) {
    $$session{direction} = $the_flow;
  }

  my $jump = 0;

  if ($from_half / 50 > rand(1)) {
    $jump = 1;
  }

  if ($from_half / 50 > rand(1.5)) {
    $$session{direction} = $the_flow * -1;
  }

  if ($$session{bpm_cur} >= $max) {
    $$session{direction} = -1;
  }

  if ($$session{bpm_cur} <= $min) {
    $$session{direction} = 1;
  }

  my $delta = $percent + ((rand(15) + 5) * $$session{direction});
  my $new_pace = int($min + (($percent + $delta) / 100 * $bpm_range));

  if ($jump) {
    my $delta = (rand(30) + 35) * $$session{direction};
    $new_pace = int($min + (($percent + $delta) / 100 * $bpm_range));

    if ($$session{direction} > 0 and $percent < 10) {
      $new_pace = $min + int((100 - rand(20)) / 100 * $bpm_range);
    }

    if ($$session{direction} < 0 and $percent > 90) {
      $new_pace = $min + int(rand(20) / 100 * $bpm_range);
    }

    if ($percent > 40 and $percent < 60) {
      if (!int(rand(8))) {
        if ($$session{direction} > 0) {
          $new_pace = $min + int((rand(.1) + .9) * $bpm_range);
        } else {
          $new_pace = $min + int(rand(.1) * $bpm_range);
        }
      }
    }
  }

  if ($new_pace > $max) {
    $new_pace = $max;
  }
  if ($new_pace < $min) {
    $new_pace = $min;
  }
  # Pause for a bit when changing direction
  if ($old_dir != $$session{direction}) {
    my $percent = (abs($$session{bpm_cur} - $min) / $bpm_range) * 100;
    my $from_half = abs($percent - 50);
    my $steady_secs = 13 * ($from_half / 50);
    steady_beats($session, $steady_secs + 1);
  }
  change_tempo($session, $new_pace);
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
