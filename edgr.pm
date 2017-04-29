package edgr;

use strict;
use DBI;
use Statistics::Basic qw(:all);
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $DEBUG);

$VERSION      = 0.1;
$DEBUG        = 0;
@ISA          = qw(Exporter);
# Functions used in scripts
@EXPORT       = qw(
                    age_sessions
                    db_connect
                    get_user_stats
                    get_user_times
                    prompt
                    save_session
                );
@EXPORT_OK    = @EXPORT;

sub age_sessions {
  my $user  = shift;
  my $dbh = db_connect();
  my $sql = 'update sessions set ttl=ttl-1 where ttl > 0 and user = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user);
  $sth->finish;
  $dbh->disconnect;
}

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
  # Get an array of session durations for $user_id
  my $user = shift;

  my $dbh = db_connect();
  my $sql = 'select length from sessions where ttl > 0 and user = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user);
  my @times = ();
  while (my ($time) = $sth->fetchrow_array) {
    push @times, $time;
  }
  $sth->finish;
  $dbh->disconnect;

  return @times;
}

sub init_session {
  my $conf = shift;

  my $session = $conf;

  update_settings($session);

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

  return $session;
}

sub make_script {
  my $session = shift;

  my $time_max = $$session{goal} * 2;

  while ($time_max > $$session{duration}) {
    make_beats($session);
    # Update sessions between generation, in case it's been changed
    update_settings($session);
  }
}

sub play {
  my $session = shift;

  make_script($session);
}

sub update_settings {
  my $session = shift;

  my $dbh = db_connect($$session{database});

  my $sql = 'select * from users where user = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($$session{user});
  my $options = $sth->fetchrow_hashref;

  foreach my $key (keys %$options) {
    $$session{$key} = $$options{$key};
  }
}

sub play_session {
  my $session = shift;

  my $command  = "aoss $$session{ctronome} -c 1 -w1 $$session{tick_file} ";
     $command .= "-w2 $$session{tock_file} -p $$session{session_script}";
  if (open my $metronome_pipe,'-|',"$command 2>/dev/null") {
    local $SIG{HUP} = sub { close $metronome_pipe; exit 0 };
    while (my $line = <$metronome_pipe>) {
      chomp $line;
      if ($line =~ /^# cmd:(.*)$/) {
        printf "%s\n" "$1";
      }
    }
    close $metronome_pipe;
  } else {
    error("Unable to open pipe: $!",3);
  }
}

sub tempo_mod {
  my $session   = shift;
  my $bpm_end   = shift;
  my $bpbpm     = shift;
  my $beats_end = shift;

  my $bpm_cur   = $$session{bpm_cur};
  $$session{duration} += $beats_end / ($bpm_end / 60);

  # Carry-over beats, to support 0.5 beats per bpm, etc.
  my $beats = 0;
  for (0 .. abs($bpm_cur - $bpm_end)) {
    $beats += $bpbpm;
    if ($beats >= 1) {
      $$session{beats} = join('#',(split(/#/,$$session{beats}),
                          sprintf('%g:%g', int($beats), $bpm_cur)));
      $$session{duration} += int($beats) / ($bpm_cur / 60);
      $beats -= int($beats);
    }
    $bpm_cur += $$session{direction};
  }

  $$session{beats} = join('#',(split(/#/,$$session{beats}),
                                    "$beats_end:$bpm_end"));
  $$session{bpm_cur} = $bpm_end;
}

sub update_tempo_limits {
  my $session = shift;

  

}

# mod_tempo(start_bpm,end_bpm,dtime,stime)
sub standard_segment {
  my $session   = shift;

  update_tempo_limits($session);

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $bpm_mid   = $$session{bpm_min} + $bpm_range / 2;
  my $bpm_pct   = abs($$session{bpm_cur} - $bpm_mid) /
                        ($$session{bpm_range} / 2);

  my $bpm_delta  = (1 - $bpm_pct) * 20;
  my $bpm_end = $$session{bpm_cur} + $bpm_delta * $$session{direction};
  my $bpm_avg = ($bpm_cur + $bpm_end) / 2;
  my $beats_delta = $time_delta * ($bpm_avg / 60);
  my $bpbpm = $beats_delta / $bpm_delta;

  my $time_end    = $bpm_pct * 20;
  my $beats_end   = int($time_end * ($bpm_end / 60));

  tempo_mod($session,$bpm_end,$bpbpm,$beats_end);
}

sub tempo_jump {
  my $session = shift;
  my $percent = shift;

  update_tempo_limits($session);

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $bpm_end   = $$session{bpm_min} + ($bpm_range * ($percent / 100));
  my $bpm_delta = abs($$state{bpm_cur} - $bpm_end);

  tempo_mod($session,$bpm_end,rand(2),int(rand(20))+5);
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
    for (0 .. int(rand(3)) + 3) {
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

  return $$session{duration};
}

sub make_session {
  my $user_id = shift;

  my $session = get_user_settings($user_id);
  ($$session{mean},$$session{std_dev}) = get_user_stats($user_id);

  $$session{goal} = $$session{mean}
      - $$session{deviations} * $$session{std_dev}
      + rand($$session{deviations} * 2 * $$session{std_dev});

  make_instructions($session)
  my $session = make_session($user_id,$goal);
  my $pass = play_session($session);
}

sub prompt {
  my $prompt = shift;
  print "$prompt: ";
  my $input = <STDIN>;
  chomp($input);
  return ($input);
}

sub save_session {
  my $user_id = shift;
  my $ttl     = shift;
  my $length  = shift;
  my $goal    = shift;
  my $mean    = shift;
  my $fails   = shift;

  my $dbh = db_connect();
  my $sql  = 'insert into sessions ';
     $sql .= '(user_id,ttl,length,goal,mean,fails) ';
     $sql .= 'values (?,?,?,?,?)';
  my $sth = $dbh->prepare($sql);

  $sth->execute($user_id,$ttl,$length,$goal,$mean,$fails);
  $sth->finish;
  $dbh->disconnect;
}
