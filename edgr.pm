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

my $dbf = "$ENV{HOME}/.config/edgr.sqlite";

sub age_sessions {
  my $user_id = shift;
  my $dbh = db_connect();
  my $sql = 'update sessions set ttl=ttl-1 where ttl > 0 and user_id = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id);
  $sth->finish;
  $dbh->disconnect;
}

sub db_connect {
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

sub get_user_options {
  my $user_id = shift;

  my $dbh = db_connect();
  my $sql = 'select * from users where userid = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id);

  my $options = $sth->fetchrow_hashref;

  $sth->finish;
  $dbh->disconnect;

  return $options;
}

sub get_user_stats {
  my $user_id = shift;

  my @times = get_user_times($user_id);
  if (scalar(@times)) {
    return mean(@times), stddev(@times);
  } else {
    return 0, 0;
  }
}

sub get_user_times {
  # Get an array of session durations for $user_id
  my $user_id = shift;

  my $dbh = db_connect();
  my $sql = 'select length from sessions where ttl > 0 and user_id = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id);
  my @times = ();
  while (my ($time) = $sth->fetchrow_array) {
    printf "%0.2f\n",$time;
    push @times, $time;
  }
  $sth->finish;
  $dbh->disconnect;

  return @times;
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

  # Carry-over beats, to support 0.5 beats per bpm, etc.
  my $beats = 0;
  for (0 .. abs($bpm_cur - $bpm_end)) {
    $beats += $bpbpm;
    if ($beats >= 1) {
      push @$session{script},int($beats) . ":$bpm_cur";
      $$session{run_time} += int($beats) / ($bpm_cur / 60);
      $beats -= int($beats);
    }
    $bpm_cur += $$session{direction};
  }

  push @$session{script},"$beats_end:$bpm_end";
  $$session{run_time} += $beats_end / ($bpm_end / 60);
  $$session{bpm_cur} = $bpm_end;
}

# mod_tempo(start_bpm,end_bpm,dtime,stime)
sub standard_segment {
  my $session   = shift;

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $bpm_mid   = $$session{bpm_min} + $$session{bpm_range} / 2;
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


  my $stime = $bpm_pct * $ttime;

  # change bpm by ($ttime / 2) to ($ttime * 2)
  my $bpm_new   = $$session{bpm_cur} + $bpm_delta;
  if ($direction < 0) {
    $bpm_new = $$session{bpm_cur} - $bpm_delta;
  }

  if ($bpm_new > $$session{bpm_max}) {
    $bpm_new = $$session{bpm_max};
  }

  if ($bpm_new < $$session{bpm_min}) {
    $bpm_new = $$session{bpm_min};
  }

  extend_session($session,$bpm_new,$dtime,$stime);
}

sub tempo_jump {
  my $session = shift;
  my $percent = shift;

  my $bpm_range = $$session{bpm_max} - $$session{bpm_min};
  my $bpm_new   = $$session{bpm_min} + ($bpm_range * ($percent / 100));
  my $bpm_delta = abs($$state{bpm_cur} - $bpm_new);

  extend_session($session,$bpm_new,$bpm_delta/3,1);
}

sub pattern_segment {
  my $session = shift;

  if (!int(rand(50))) {
    for (0 .. int(rand(3)) + 1) {
      tempo_jump($session,rand(20) + 40);
      tempo_jump($session,rand(20) + 80);
    }
  } elsif (!int(rand(50))) {
    for (0 .. int(rand(3)) + 1) {
      tempo_jump($session,rand(20) + 40);
      tempo_jump($session,rand(20));
    }
  } else {
    my $direction = 1;
    if (int(rand(2))) {
      $direction = -1;
    }
    for (0 .. int(rand(3)) + 3) {
      standard_segment($session,rand(11) + 5,$direction);
    }
  }
}

sub build_session {
  my $session = shift;

  while ($$session{time_cur} < $$session{time_end}) {
    my $time_std = rand(10) + rand(10) + 5;
    if (int(rand(2)) == 0) {
      standard_segment($session,$time_std,1);
    } else {
      standard_segment($session,$time_std,-1);
    }

    if (int(rand($$session{pattern_chance})) == 0) {
      $$session{pattern_chance} = $$session{pattern_freq};
      pattern_segment($session);
    } else {
      $$session{pattern_chance}--;
    }
  }
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