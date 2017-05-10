package edgr;

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

sub get_times {
  my $session = shift;

  my $dbh = db_connect($$session{database});
  my $sql = qq{
select length from sessions where user = ? and
date between datetime('now', '-14 days') and datetime('now', 'localtime')
order by date desc limit ?
  };
  my $sth = $dbh->prepare($sql);
  $sth->execute($$session{user},$$session{past_sessions});
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

  $$session{goal} = int(($$session{mean} - $$session{stddev}) +
                        (rand($$session{stddev}) * 2));
  $$session{time_max} = $$session{goal} * 3;

  update_tempo_limits($session);
  $$session{bpm_cur} = $$session{bpm_min} +
            int(rand(($$session{bpm_max} - $$session{bpm_min}) * 3 / 5));

  $$session{direction} = 1;

  $$session{lube_next} = $$session{lube_break};

  $$session{prize_armed} = $$session{prize_enabled};
  $$session{liquid_silk} = 0;
  $$session{lubed} = 0;
  $$session{prized} = 0;

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
          printf $script_fh "# %s\n", $command;
          #printf "# %s\n", $command;
        }
        $$session{duration} += 60  / $bpm;
        printf $script_fh "1 %g/4 2/8\n", $bpm;
        #printf "1 %g/4 2/8\n", $bpm;
        $count--;
      }
    }
    close $script_fh;
  } else {
    error("Unable to open script ($$session{script_file}): $!",1);
  }
}

#sub play_script {
#  my $session = shift;
#
#  my $command  = "aoss $$session{ctronome} -c 1 -w1 $$session{tick_file} ";
#     $command .= "-w2 $$session{tock_file} -p $$session{script_file}";
#  if (open my $metronome_pipe,'-|',"$command 2>/dev/null") {
#    local $SIG{HUP} = sub { close $metronome_pipe; exit 0 };
#    while (my $line = <$metronome_pipe>) {
#      chomp $line;
#      if ($line =~ /^# (.*)$/) {
#        printf "%s\n", "$1";
#      }
#    }
#    close $metronome_pipe;
#  } else {
#    error("Unable to open pipe: $!",3);
#  }
#}

sub play_script {
  my $session = shift;

  my $start = time();
  my @args = ("aoss","$$session{ctronome}","-c1", "-w1", "$$session{tick_file}",
              "-w2", "$$session{tock_file}", "-p", "$$session{script_file}");
  system(@args);
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

sub update_tempo_limits {
  my $session = shift;

  my $min_range = $$session{bpm_min_max} - $$session{bpm_min_min};
  my $max_range = $$session{bpm_max_max} - $$session{bpm_max_min};

  my $min_add = 0;
  my $max_add = 0;
  if ($$session{duration} > $$session{time_max} / 2) {
    my $time = $$session{duration} - $$session{time_max} / 2;
    my $percent = $time / ($$session{time_max} / 2);
    $min_add = $percent * ($min_range * 4 / 7) + ($min_range * 3 / 7);
    $max_add = $percent * ($max_range * 1 / 8) + ($max_range * 7 / 8);
  } elsif ($$session{duration} > $$session{time_max} / 3) {
    my $time = $$session{duration} - $$session{time_max} / 3;
    my $percent = $time / ($$session{time_max} / 6);
    $min_add = $percent * ($min_range * 2 / 7) + ($min_range * 1 / 7);
    $max_add = $percent * ($max_range * 4 / 8) + ($max_range * 3 / 8);
  } elsif ($$session{duration} > $$session{time_max} / 4) {
    my $time = $$session{duration} - $$session{time_max} / 4;
    my $percent = $time / ($$session{time_max} / 6);
    $min_add = $percent * ($min_range * 1 / 7);
    $max_add = $percent * ($max_range * 2 / 8) + ($max_range * 1 / 8);
  } else {
    my $time = $$session{duration};
    my $percent = $time / ($$session{time_max} / 6);
    $min_add = 0;
    $max_add = $percent * ($max_range * 1 / 8);
  }

  $$session{bpm_min} = $$session{bpm_min_min} + int($min_add);
  $$session{bpm_max} = $$session{bpm_max_min} + int($max_add);
}

sub change_tempo {
  my $session = shift;
  my $percent = shift;
  my $bpbpm   = shift;

  update_tempo_limits($session);

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $bpm_end   = $$session{bpm_min} + ($bpm_range * ($percent / 100));

  if ($bpm_end > $$session{bpm_max}) {
    $bpm_end = $$session{bpm_max};
  }

  if ($bpm_end < $$session{bpm_min}) {
    $bpm_end = $$session{bpm_min};
  }

  # Carry-over beats, to support 0.5 beats per bpm, etc.
  my $beats = 0;
  my $bpm_delta = abs($bpm_end - $$session{bpm_cur});

  while ($bpm_delta > 0) {
    $beats += $bpbpm;
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

sub make_beats {
  my $session = shift;

  update_tempo_limits($session);

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $percent = (($$session{bpm_cur} - $$session{bpm_min}) / $bpm_range) * 100;

  if (($percent < 10 and $$session{direction} == -1) or
      ($percent > 90 and $$session{direction} == 1)) {
    my $bpbpm = rand(2) + 0.5;

    # Chance to peak
    if (!int(rand(3))) {
      if ($percent > 90) {
        change_tempo($session,100,$bpbpm);
      } else {
        change_tempo($session,0,$bpbpm);
      }
      steady_beats($session,rand(25) + 5);
    }

    # Reverse direction
    $$session{direction} *= -1;

    # Chance to go to the other end
    if (!int(rand(4))) {
      if ($percent > 90) {
        change_tempo($session, 10 + rand(10), $bpbpm);
      } else {
        change_tempo($session, 90 - rand(10), $bpbpm);
      }
    } else {
      change_tempo($session, 40 + rand(20), $bpbpm);
    }
    steady_beats($session,rand(10)+10);
  } else {
    if ($percent > 40 and $percent < 60) {
      if (!int(rand(3))) {
        # Reverse direction
        $$session{direction} *= -1;
      }
    }

    my $new_pct = ((rand(8) + 2) * $$session{duration}) + $percent;

    change_tempo($session,$new_pct,0.75 + rand(2.5));
    steady_beats($session,rand(15)+5);
  }
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
