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
  my $sql = qq{select length from sessions where user = ? and date between
    datetime('now', '-6 days') and datetime('now', 'localtime')};
  my $sth = $dbh->prepare($sql);
  $sth->execute($$session{user});
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

  $$session{goal} = $$session{mean} - ($$session{bonus} * $$session{stddev}) +
              rand(($$session{malus} + $$session{bonus}) * $$session{stddev});
  $$session{time_max} = $$session{goal} * 2;

  update_tempo_limits($session);
  $$session{bpm_cur} = $$session{bpm_min} +
            int(rand($$session{bpm_max} - $$session{bpm_min}));

  $$session{direction} = 1;
  if (int(rand(2))) {
    $$session{direction} *= -1;
  }

  $$session{lube_next} = $$session{lube_break};
  $$session{pattern_chance} = $$session{pattern_reset};

  return $session;
}

sub maybe_add_command {
  my $session = shift;

  my $command = undef;

  if ($$session{duration} > $$session{lube_next}) {
    if (!int(rand($$session{lube_chance}))) {
      $command = "Use lube";
      $$session{lube_next} = $$session{duration} + $$session{lube_break};
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

sub tempo_mod {
  my $session   = shift;
  my $bpm_end   = shift;
  my $bpbpm     = shift;
  my $beats_end = shift;

  my $bpm_cur = $$session{bpm_cur};

  # Carry-over beats, to support 0.5 beats per bpm, etc.
  my $beats = 0;

  # Fix direction if it is broken
  $$session{direction} = 1;
  if ($bpm_cur > $bpm_end) {
    $$session{direction} = -1;
  }

  while (int($bpm_cur) != int($bpm_end)) {
    $beats += $bpbpm;
    if (int($beats) > 0) {
      $$session{beats} = join('#',(split(/#/,$$session{beats}),
                          sprintf('%g:%g', int($beats), $bpm_cur)));
      $$session{duration} += int($beats) * 60 / $bpm_cur;
      $beats -= int($beats);
    }
    $bpm_cur += $$session{direction};
  }

  $$session{beats} = join('#',(split(/#/,$$session{beats}),
                                    "$beats_end:$bpm_end"));
  $$session{duration} += $beats_end * 60 / $bpm_end;
  $$session{bpm_cur} = $bpm_end;
}

sub update_tempo_limits {
  my $session = shift;

  my $min_range = $$session{bpm_min_max} - $$session{bpm_min_min};
  my $max_range = $$session{bpm_max_max} - $$session{bpm_max_min};

  # duration from 0 to 1/4 maximum time
  my $time = $$session{duration};
  my $percent = $time / ($$session{time_max} / 4);
  my $min_add = (3/8) * $min_range * $percent;
  my $max_add = (1/8) * $max_range * $percent;

  if ($$session{duration} >= $$session{time_max} / 4) {
    $time = $$session{duration} - ($$session{time_max} / 4);
    $percent = $time / ($$session{time_max} / 4);
    $min_add = (3/8) * $min_range + ((1/8) * $min_range * $percent);
    $max_add = (1/8) * $max_range + ((3/8) * $max_range * $percent);
  }

  if ($$session{duration} >= $$session{time_max} / 2) {
    $time = $$session{duration} - ($$session{time_max} / 2);
    $percent = $time / ($$session{time_max} / 4);
    $min_add = ($min_range / 2) + ((1/8) * $min_range * $percent);
    $max_add = ($max_range / 2) + ((3/8) * $max_range * $percent);
  }

  if ($$session{duration} >= $$session{time_max} * 3 / 4) {
    $time = $$session{duration} - ($$session{time_max} * 3 / 4);
    $percent = $time / ($$session{time_max} / 4);
    $min_add = (5/8) * $min_range + ((3/8) * $min_range * $percent);
    $max_add = (7/8) * $max_range + ((1/8) * $max_range * $percent);
  }

  $$session{bpm_min} = $$session{bpm_min_min} + $min_add;
  $$session{bpm_max} = $$session{bpm_max_min} + $max_add;
}

sub standard_segment {
  my $session   = shift;

  update_tempo_limits($session);

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $bpm_mid   = $$session{bpm_min} + $bpm_range / 2;
  my $bpm_pct   = abs($$session{bpm_cur} - $bpm_mid) / ($bpm_range / 2);

  my $bpm_delta = (((1 - $bpm_pct) * 28) + 2);

  my $bpm_end = $$session{bpm_cur} + ($bpm_delta * $$session{direction});

  if ($bpm_end > $$session{bpm_max}) {
    $bpm_end = $$session{bpm_max};
  }
  if ($bpm_end < $$session{bpm_min}) {
    $bpm_end = $$session{bpm_min};
  }

  my $bpm_avg = ($$session{bpm_cur} + $bpm_end) / 2;

  my $time_end    = ($bpm_pct * 18) + 2;
  my $beats_end   = int(($time_end * $bpm_end) / 60);

  my $time_delta  = ((1 - $bpm_pct) * 18) + 2;
  my $beats_delta = int(($time_delta * $bpm_avg) / 60);

  my $bpbpm = $beats_delta / $bpm_delta;

  tempo_mod($session,int($bpm_end),$bpbpm,$beats_end);
}

sub tempo_jump {
  my $session = shift;
  my $percent = shift;

  update_tempo_limits($session);

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $bpm_end   = $$session{bpm_min} + ($bpm_range * ($percent / 100));

  if ($bpm_end > $$session{bpm_max}) {
    $bpm_end = $$session{bpm_max};
  }

  if ($bpm_end < $$session{bpm_min}) {
    $bpm_end = $$session{bpm_min};
  }

  tempo_mod($session,int($bpm_end),rand(2),int(rand(20))+5);
}

sub pattern_segment {
  my $session = shift;

  if (!int(rand(50))) {
    for (0 .. int(rand(3)) + 1) {
      tempo_jump($session, 40 + rand(20));
      tempo_jump($session, 80 + rand(20));
    }
  } elsif (!int(rand(50))) {
    for (0 .. int(rand(3)) + 1) {
      tempo_jump($session, 40 + rand(20));
      tempo_jump($session,  0 + rand(20));
    }
  } else {
    for (0 .. int(rand(3)) + 2) {
      standard_segment($session);
    }
  }
}

sub make_beats {
  my $session = shift;

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $percent = ($$session{bpm_cur} - $$session{bpm_min}) / $bpm_range;

  if ($percent > 0.3 and $percent < 0.7) {
    if (int(rand(2))) {
      $$session{direction} *= -1;
    }
  }

  if (($percent < 0.05 and $$session{direction} == -1) or
     ($percent > 0.95 and $$session{direction} == 1)) {
    tempo_jump($session, 40 + rand(20));
  }

  if (($percent > 0.7 and $$session{direction} == -1) or
     ($percent < 0.3 and $$session{direction} == 1)) {
    if (int(rand(3))) {
      $$session{direction} *= -1;
    }
  }

  standard_segment($session);

  if (!int(rand($$session{pattern_chance}))) {
    $$session{pattern_chance} = $$session{pattern_reset};
    pattern_segment($session);
  } else {
    $$session{pattern_chance}--;
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
