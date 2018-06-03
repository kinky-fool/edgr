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

sub last_session {
  my $dbh     = shift;
  my $user_id = shift;

  my $sql = 'select id from sessions
                where user_id = ? order by id desc limit 1';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id);
  my ($session_id) = $sth->selectrow_array;

  $sth->finish

  if ($session_id) {
    return $session_id;
  }

  printf STDERR "error: Unable to get previous session_id for %s\n", $username;
  return undef;
}

sub get_session {
  my $dbh       = shift;
  my $sess_id   = shift;

  my $sql = 'select key, val from session_settings where session_id = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($sess_id);
  my $session = $sth->selectall_hashref('key');

  if ($session) {
    return $session;
  }

  printf STDERR "error: Unable to load session data for session %s: %s",
                  $sess_id, $!;
  return undef;
}

sub deny_play {
  my $dbh   = shift;
  my $user  = shift;

  my $session_id  = last_session($dbh, $$user{user_id});
  my $session     = get_session($dbh, $session_id);

  my $since = time - $$session{time_end};

  if ($$user{cooldown} > time - $$session{time_end}) {
    my $wait = $$user{cooldown} - (time - $$session{time_end});
    printf "Wait %s longer\n", sec_to_human_precise($wait);
    return 1;
  }

  return 0;
}

sub error {
  my $message = shift;
  my $rv      = shift;

  printf STDERR "error: %s\n",$message;
  if ($rv >= 0) {
    exit $rv
  }
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

sub get_user {
  my $dbh       = shift;
  my $username  = shift;

  my $sql = 'select key, val from user_settings
              join users on users.id = user_settings.user_id
              where users.username = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($username);

  my $user = $sth->fetchall_hashref('key');

  $sth->finish;

  if ($user) {
    return $user;
  }

  printf STDERR "error: Unable to get user '%s': %s\n", $username, $!;
  exit 1;
}

sub init_session {
  my $dbh   = shift;
  my $user  = shift;

  my %session = ();

  $session{duration}  = 0;

  $session{round_id}  = $$user{round};
  $session{inning_id} = $$user{inning};
  $session{safe_min}  = $$user{end_zone_start};
  $session{safe_max}  = $$user{end_zone_length};
  $session{slow_next} = $session{safe_max} + $$user{slow_start};
  $session{slow_one}  = $session{slow_next};
  $session{bpm_cur}   = $$user{bpm_min};
  $session{bpm_min}   = $$user{bpm_min};
  $session{bpm_max}   = $$user{bpm_max};

  my $sql = 'insert into sessions (user_id) values ( ? )';
  my $sth = $dbh->prepare($sql);
  my $rv = $sth->execute($$user{user_id});

  $sth->finish;

  if ($rv) {
    my $sql = 'select last_insert_rowid()';
    my $sth = $dbh->prepare($sql);
    $sth->execute;
    ($session_id) = $sth->fetchrow_array;

    $sth->finish;
  } else {
    error("error: Unable to create session.",1);
  }

  if ($session_id) {
    $session{session_id} = $session_id;
  }

  return \%session;
}

sub store_session {
  my $dbh     = shift;
  my $session = shift;

  my $sql = 'insert or replace into session_settings (session_id, key, val)
              values ( ?, ?, ? )';
  my $sth = $dbh->prepare($sql);

  foreach my $key (keys %$session) {
    my $rv = $sth->execute($$session{session_id}, $key, $$session{$key});
    unless ($rv) {
      error("Store session; $key: $$session{key} failed",-1);
    }
  }

  $sth->finish;
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

sub evaluate_session {
  my $session = shift;

  if ($$session{length} > $$session{too_slow}) {
    if ($$session{passes_per_slow} > 0) {
      my $over_by = $$session{length} - $$session{too_slow};
      my $count = int($over_by / $$session{too_slow_interval}) + 1;
      $$session{owed_passes} += $$session{passes_per_slow} * $count;
      $$session{passes_per_slow}--;
    }
  }

  if ($$session{safe_min} > $$session{length} or
      $$session{length} > $$session{safe_max}) {
    # Session failed
    if ($$session{passes_per_fail} > 0) {
       $$session{owed_passes} += $$session{passes_per_fail};
    }
  } else {
    # Session passed
    $$session{slow_tripwire} = 0;
    $$session{passes_per_slow} = 0;
  }

  if ($$session{length} >= $$session{mean}) {
    # Increment passes added for taking too long
    if ($$session{slow_tripwire}) {
      $$session{passes_per_slow}++;
      if ($$session{too_slow_rand}) {
        # Random time in seconds between max_safe and adding passes
        $$session{too_slow_start} = rand(150) + 30;
        # Random time in seconds between added passes
        $$session{too_slow_interval} = rand(50) + 10;
      }
    } else {
      # Set the tripwire for taking too long
      $$session{slow_tripwire} = 1;
    }
  }
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

  # Evaluate the current session
  evaluate_session($session);

  # Examine past sessions
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

    if ($$sess{length} >= $$sess{safe_min} and
        $$sess{length} <= $$sess{safe_max}) {
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
    if ($$session{verbose} > 2) {
      my $remaining = $$session{owed_passes} - $pass;
      printf "%s pass%s until next bead draw.\n",
              $remaining, ($remaining==1)?'':'es';
    }
  }

  # Fail if player has not achieved the required pass/fail percent
  my $percent = ($pass / ($pass + $fail)) * 100;
  if ($$session{owed_percent} > $percent) {
    $passed = 0;
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


    if ($$session{verbose} > 0) {
      printf "%s Passes - %s Fails - Draw a bead!\n", $pass, $fail;
      if ($$session{verbose} > 1) {
        printf "%s pass%s required for next draw.\n",
                  $$session{owed_passes},
                  ($$session{owed_passes} == 1)?'':'es';
      }
    } else {
      printf "Draw a bead!\n"
    }

  } else {
    printf "More sessions required.\n";
  }

  store_settings($session);
}

sub store_settings {
  my $session = shift;

  my @keys = qw(
    too_slow_start
    too_slow_interval
    slow_tripwire
    passes_per_slow
    passes_per_fail
    owed_streak
    owed_passes
    owed_passes_default
    owed_percent
  );

  my $user_id = $$session{user_id};
  my $dbh = db_connect($$session{database});
  my $sql = 'insert or replace into settings (user_id, key, value)
                                              values (?, ?, ?)';
  my $sth = $dbh->prepare($sql);

  foreach my $key (@keys) {
    my $rv = $sth->execute($user_id, $key, $$session{$key});

    unless ($rv) {
      printf "error: unable to update %s -> %s for user_id: %s\n",
                $key, $$session{$key}, $user_id;
    }
  }

  $sth->finish;
  $dbh->disconnect;
}

sub set_messages {
  my $session = shift;

  my @all_messages = qw(
    safe_min
    safe_max
    too_slow
    tripwire_set
    tripwire_tripped
    sessions_remaining
    sessions_reset_val
    round_passes
    round_fails
  );

  my @messages = @all_messages;
  unless ($$session{messages} =~ /\ball\b/) {
    @messages = split(/\s+/, $$session{messages});
  }

  foreach my $message (@messages) {
    my $valid = 0;
    foreach my $valid_message (@all_messages) {
      if ($message eq $valid_message) {
        $valid = 1;
      }
    }

    if ($valid) {
      $$session{"tell_${message}"} = 1;
    } else {
      printf STDERR "Unknown message type: %s\n", $message;
    }
  }
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

sub write_script {
  my $session   = shift;
  my $settings  = shift;

  my $untripped = 1;
  my $tell_safe = 1;
  my $tell_fail = 1;
  my $tell_slow = 1;

  # Reset for interleaving the commands
  $$session{duration} = 0;
  if (open my $script_fh,'>',$$settings{script_file}) {
    foreach my $beat (split(/#/,$$session{beats})) {
      my ($count,$bpm) = split(/:/,$beat);

      while ($count > 0) {
        if ($$session{duration} > $$session{safe_min}) {
          if ($$session{verbose} > 0 and $tell_safe) {
            $tell_safe = 0;
            printf $script_fh "# Minimum time reached.\n";
          }
        }

        if ($$session{duration} > $$session{safe_max}) {
          if ($$session{verbose} > 2 and $tell_fail) {
            $tell_fail = 0;
            printf $script_fh "# Too late...\n";
          }
        }

        if ($$session{duration} > $$session{too_slow_next}) {
          if ($$session{verbose} > 0 and $tell_slow) {
            if ($$session{passes_per_slow} or $$session{verbose} > 1) {
              printf $script_fh "# Too slow...\n";
              $$session{too_slow_next} += $$session{too_slow_interval};
            } else {
              $tell_slow = 0;
            }
          }
        }

        if ($$session{duration} > $$session{mean}) {
          if ($$session{verbose} > 1 and $untripped) {
            $untripped = 0;
            if ($$session{slow_tripwire}) {
              printf $script_fh "# Tripwire tripped.\n";
            } else {
              printf $script_fh "# Tripwire set.\n";
            }
          }
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
  $$session{length} = abs($start - time());
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
  my ($session, $direction) = @_;

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

sub tempo_rate_time {
  my $session = shift;
  my $tempo = shift;
  my $rate = shift;
  my $time = shift;

  change_tempo($session, $$session{bpm_cur} + $tempo, $rate);
  steady_beats($session, $time);
}

sub make_beats {
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
