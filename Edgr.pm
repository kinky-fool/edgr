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
@EXPORT       = qw( do_session read_config get_settings set_settings );
@EXPORT_OK    = @EXPORT;

sub beat_time {
  my @beats = @_;

  my $time = 0;

  foreach my $beat (@beats) {
    my ($count, $bpm) = split(/:/, $beat);
    $time += $count * 60 / $bpm;
  }

  return $time;
}

sub change_tempo {
  my $bpm     = shift;
  my $bpm_min = shift;
  my $bpm_max = shift;
  my $bpm_new = shift;
  my $rate    = shift;

  my $dir     = 1;
  if ($bpm > $bpm_new) {
    $dir = -1;
  }

  my @beats = ();

  my $bpm_delta = abs($bpm - $bpm_new);

  while ($bpm_delta > 0) {
    my $seconds = seconds_per_bpm($bpm, $bpm_min, $bpm_max, $dir) * $rate;

    push @beats, steady_beats($bpm, $seconds);

    $bpm += $dir;

    $bpm_delta--;
  }

  return @beats;
}

sub check_cooldown {
  my $dbh     = shift;
  my $user_id = shift;

  my $session_id  = get_session_id($dbh, $user_id);
  if ($session_id) {
    my $user        = read_data($dbh, $user_id, 'user', 10);
    my $session     = read_data($dbh, $session_id, 'session', 10);

    if ($$session{valid} == 1) {
      my $remaining = $$session{time_end} - (time - $$user{cooldown});
      if ($remaining > 0) {
        printf "Wait %s longer\n", sec_to_human_precise($remaining);
        exit;
      }
    }
  }
}

sub db_connect {
  my $dbf = shift;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dbf","","") ||
    error("could not connect to database: $!",1);
  return $dbh;
}

sub do_session {
  my $options = shift;

  my $dbh     = db_connect($$options{database});
  my $user_id = get_user_id($dbh, $$options{user});

  # See if player has waited long enough to start a new session
  check_cooldown($dbh, $user_id);

  # Create a new session
  my $session = init_session($dbh, $user_id);

  # Save session data
  write_data($dbh, $session, 'session');

  # Create the tempo program
  my @beats = make_beats($$session{bpm_min}, $$session{bpm_max},
                                              $$session{time_max});

  # Generate the stroke tempo "program"
  write_script($$options{script_file}, $session, @beats);

  # Tweet that the session has started
  my $message = sprintf "Session #%s started.", $$session{id};
  twitters($options, $message);

  # Spawn ctronome and play the script (fork this?)
  my $command  = "aoss $$options{ctronome} -c 1 -w1 $$options{tick_file} ";
     $command .= "-w2 $$options{tock_file} -p $$options{script_file}";
  system($command);

  # Record time that session ended
  $$session{time_end} = time;

  # Time session lasted
  my $elapsed = $$session{time_end} - $$session{time_start};

  # Mark session as valid if it was not out of bounds in length
  if ($elapsed > $$session{time_min} and $elapsed < $$session{time_max}) {
    $$session{valid} = 1;
  }

  # Save session data
  write_data($dbh, $session, 'session');

  # Load the player's settings
  my $user = read_data($dbh, $user_id, 'user', 10);

  # Evaluate the session and update settings
  eval_session($session, $user);

  # Get the ID of the current set
  my $set_id = get_set_id($dbh, $user_id);

  # Load all the sessions from a set into %$set
  my $set = get_sessions_by_keyval($dbh, 'set_id', $set_id);

  # Evaluate the sessions in the set to see if the set is completed
  my ($complete, $num_pass, $num_fail) = eval_set($set, $user);

  my $num_sessions = $num_pass + $num_fail;

  if ($complete) {
    # Set player challenges for next set
    $$user{streak_owed}   = $$user{streak_next};
    $$user{sessions_owed} = $$user{sessions_next};
    $$user{time_owed}     = $$user{time_next};

    # Increment streak required every new set
    if ($$user{set_bonus} > 0) {
      $$user{streak_next} += $$user{set_bonus};
    }

    printf "Set complete! Draw a bead!\n";

    if ($$user{verbose} > 0) {
      printf "%s out of %s (%0.2g%%) session%s passed.\n",
              $num_pass, $num_sessions, ($num_pass / $num_sessions)*100,
              ($num_sessions == 1) ? '' : 's';
    }

    if ($$user{verbose} > 1) {
      printf "New set begins with %s session%s owed.\n",
                $$user{sessions_owed},
                ($$user{sessions_owed} == 1) ? '' : 's';
    }

    my $message = sprintf "Set completed after %s session%s. " .
                          "New set begins with %s session%s owed.",
                          $num_sessions, ($num_sessions == 1) ? '' : 's',
                          $$user{sessions_owed},
                          ($$user{sessions_owed} == 1) ? '' : 's';

    twitters($options, $message);

    # Reset tripwire when a set is passed
    $$user{trip_ped} = 0;

    # Start a new set
    new_set($dbh, $user_id);
  } else {
    printf "More sessions required.\n";
  }

  write_data($dbh, $session, 'session');
  write_data($dbh, $user, 'user');

  # Clean up
  $dbh->disconnect;
}

sub error {
  my $message = shift;
  my $rv      = shift;

  printf STDERR "Error: %s\n",$message;
  if ($rv >= 0) {
    exit $rv
  }
}

sub eval_session {
  my $session = shift;
  my $user    = shift;

  my $elapsed = abs($$session{time_end} - $$session{time_start});

  if ($$session{trip_ped}) {
    if ($elapsed > $$session{slow_time}) {
      if ($$user{slow_penalty} > 0) {
        my $over_by = $elapsed - $$session{slow_time};
        my $count   = int($over_by / $$session{slow_grace}) + 1;
        my $penalty = $count * $$user{slow_penalty};

        if ($$user{all_or_nothing} > 0) {
          if ($$user{slow_percent} >= rand(100) + 1) {
            $$session{penalties} += $penalty
          }
        } else {
          for (1 .. $penalty) {
            if ($$user{slow_percent} >= rand(100) + 1) {
              $$session{penalties}++;
            }
          }
        }
      }
    }
  }

  if ($$session{trip_on}) {
    if ($elapsed > $$session{trip_time}) {
      # Set the tripwire for taking too long
      $$session{trip_ped} = 1;
    }
  }

  if ($elapsed => $$user{goal_min} and $elapsed <= $$user{goal_max}) {
    # Session passed
    # If the option trip_reset is set, reset the trip_ped flag
    if ($$user{trip_reset}) {
      $$user{trip_ped} = 0;
    }
  } else {
    # Session failed
    if ($$user{all_or_nothing} > 1) {
      if ($$user{fail_percent} >= rand(100) + 1) {
        $$session{penalties} += $$user{fail_penalty};
      }
    } else {
      for (1 .. $$user{fail_penalty}) {
        # If the fail percent is high enough, increment penalty sessions
        if ($$user{fail_percent} >= rand(100) + 1) {
          $$session{penalties}++;
        }
      }
    }

    $$user{sessions_owed} += $$session{penalties};
  }
}

sub eval_set {
  my $set   = shift;
  my $user  = shift;

  my $streak      = 0;
  my $max_streak  = 0;

  my $num_pass    = 0;
  my $num_fail    = 0;

  my $time_stroke = 0;

  my $session_id  = '';

  my $streak_broke  = 0;
  my $penalties     = 0;

  foreach my $key (sort keys %$set) {
    my $session = $$set{$key};

    if ($$session{valid}) {
      my $passed = 0;
      my $length = abs($$session{time_end} - $$session{time_start});

      $streak++;

      if ($length > $$session{goal_min} and $length < $$session{goal_max}) {
        $num_pass++;
        $passed = 1;
        $streak_broke = 0;
      } else {
        $streak = 0;
        $num_fail++;
        $streak_broke = 1;
      }

      if ($streak > $max_streak) {
        $max_streak = $streak;
      }

      $time_stroke += $length;
      $penalties = $$session{penalties};
    }
  }

  if ($$user{verbose} > 0 and $streak_broke and $$user{streak_owed}) {
    printf "Streak ended. :(\n";
  }

  if ($$user{verbose} > 1 and $penalties) {
    printf "Earned %s extra session%s! ;)\n", $penalties,
                                      ($penalties == 0) ? '' : 's";
  }

  # Flag for passing any set challenges (no challege = pass)
  my $passed = 1;

  # Fail if player owes a better streak of passed sessions
  if ($$user{streak_owed} > $max_streak) {
    $passed = 0;
  }

  # Fail if the last session doesn't end in a satisfactory streak
  if ($$user{streak_finish} and $$user{streak_owed} > $streak) {
    $passed = 0;
  }

  # Fail if player owes more time
  if ($$user{time_owed} > $time_stroke) {
    $passed = 0;
  }

  # Fail if player owes more sessions
  if ($$user{sessions_owed} > ($num_pass + $num_fail)) {
    $passed = 0;
    my $owed = $$user{sessions_owed} - ($num_pass + $num_fail);
    if ($$user{verbose} > 2) {
      printf "%s pass%s until next bead draw.\n",
              $owed, ($owed == 1) ? '' : 'es';
    }
  }

  return ($passed, $num_pass, $num_fail);
}

sub get_sessions_by_keyval {
  my $dbh = shift;
  my $key = shift;
  my $val = shift;

  my %sessions = ();

  my $sql = 'select session_id from session_data where key = ? and val = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($key, $val);

  while (my ($session_id) = $sth->fetchrow_array) {
    my $session = read_data($dbh, $session_id, 'session', 10);
    $sessions{$$session{time_end}} = $session;
  }

  $sth->finish;

  return \%sessions;
}

sub get_session_id {
  my $dbh     = shift;
  my $user_id = shift;

  my $sql = 'select id from sessions where user_id = ?
              order by id desc limit 1';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id);
  my ($session_id) = $sth->fetchrow_array;

  $sth->finish;

  if ($session_id) {
    return $session_id;
  }

  error("Unable to get session_id for $user_id", -1);
}

sub get_set_id {
  my $dbh     = shift;
  my $user_id = shift;

  my $sql = 'select id from sets where user_id = ?
              order by id desc limit 1';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user_id);
  my ($set_id) = $sth->fetchrow_array;

  $sth->finish;

  if ($set_id) {
    return $set_id;
  } else {
    my $set_id = new_set($dbh, $user_id);
    if ($set_id) {
      return $set_id;
    }
  }

  error("Unable to get set_id for $user_id", 1);
}

sub get_settings {
  my $options = shift;
  my $key     = shift;

  my $show_hidden = 0;
  if (defined $key and $key eq 'hidden') {
    $show_hidden = 1;
    $key = undef;
  }

  my $dbh = db_connect($$options{database});
  my $user_id = get_user_id($dbh, $$options{user});

  my $see_val = read_data($dbh, $user_id, 'user', 2);
  my $see_set = read_data($dbh, $user_id, 'user', 3);

  my %keys = ();
  foreach my $key (keys %$see_val, keys %$see_set) {
    $keys{$key} = 1;
  }

  if (defined $key) {
    if ($key =~ /%/) {
      $key =~ s/%/.*/g;
      foreach my $wildkey (grep { /^$key$/i } keys %keys) {
        if (defined $$see_val{$wildkey}) {
          printf "%-15s%10s\n", "$wildkey:", $$see_val{$wildkey};
        } elsif (defined $$see_set{$wildkey}) {
          printf "%-15s%10s\n", "$wildkey:", "[hidden]";
        }
      }
    } else {
      if (defined $$see_val{$key}) {
        printf "%-15s%10s\n", "$key:", $$see_val{$key};
      } elsif (defined $$see_set{$key}) {
        printf "%-15s%10s\n", "$key:", "[hidden]";
      } else {
        printf "%-15s%10s\n", "$key:", "[unknown]";
      }
    }
  } else {
    foreach my $key (sort %keys) {
      if (defined $$see_val{$key}) {
        printf "%-15s%10s\n", "$key:", $$see_val{$key};
      } elsif (defined $$see_set{$key} and $show_hidden) {
        printf "%-15s%10s\n", "$key:", "[hidden]";
      }
    }
  }

  $dbh->disconnect;
}

sub get_user_id {
  my $dbh   = shift;
  my $user  = shift;

  my $sql = 'select id from users where name = ?';
  my $sth = $dbh->prepare($sql);
  $sth->execute($user);
  my ($user_id) = $sth->fetchrow_array;

  $sth->finish;

  if ($user_id) {
    return $user_id;
  }

  error("Unable to get user_id for $user", 1);
}

sub init_session {
  my $dbh     = shift;
  my $user_id = shift;

  my $session = new_session($dbh, $user_id);
  my $user    = read_data($dbh, $user_id, 'user', 10);

  $$session{bpm_min}      = $$user{bpm_min};
  $$session{bpm_max}      = $$user{bpm_max};
  $$session{time_min}     = $$user{time_min};
  $$session{time_max}     = $$user{time_max};
  $$session{goal_min}     = $$user{goal_min};
  $$session{goal_max}     = $$user{goal_max};
  $$session{slow_time}    = $$user{goal_min} + $$user{slow_after};
  $$session{slow_grace}   = $$user{slow_grace};
  $$session{slow_penalty} = $$user{slow_penalty};
  $$session{trip_on}      = $$user{trip_on};
  $$session{trip_time}    = $$user{goal_max} + $$user{trip_after};
  $$session{trip_ped}     = $$user{trip_ped};
  $$session{verbose}      = $$user{verbose};

  return $session;
}

sub make_beats {
  my $bpm_min   = shift;
  my $bpm_max   = shift;
  my $time_max  = shift;

  my $bpm       = $bpm_min;

  my $bpm_range = abs($bpm_max - $bpm_min);
  my $steps     = 6;
  my $step_size = $bpm_range / $steps;

  my @beats = ();

  push @beats, steady_beats($bpm, 10);

  while ($time_max > beat_time(@beats)) {
    for my $loop (3 .. $steps) {
      for (1 .. $loop) {
        push @beats, change_tempo($bpm, $bpm_min, $bpm_max,
                                    $bpm + $step_size, 0.2 + (0.1 * $loop));
        push @beats, steady_beats($bpm + $step_size, 5);
        $bpm = $bpm + $step_size;
      }

      push @beats, steady_beats($bpm, 10);

      my $diff = abs($bpm - $bpm_min);

      my $step = $diff / 4;
      push @beats, change_tempo($bpm, $bpm_min, $bpm_max, $bpm - $step, 0.6);
      push @beats, steady_beats($bpm - $step, 5 + $loop);
      $bpm = $bpm - $step;

      $step = $diff / 3;
      push @beats, change_tempo($bpm, $bpm_min, $bpm_max, $bpm - $step, 0.8);
      push @beats, steady_beats($bpm - $step, 5 + $loop);
      $bpm = $bpm - $step;

      $step = $diff - ($diff / 4 + $diff / 3);
      push @beats, change_tempo($bpm, $bpm_min, $bpm_max, $bpm - $step, 1.2);
      push @beats, steady_beats($bpm - $step, 10 + $loop * 2);
      $bpm = $bpm - $step;
    }
  }

  return @beats;
}

sub new_session {
  my $dbh     = shift;
  my $user_id = shift;

  my $sql = 'insert into sessions (user_id) values ( ? )';
  my $sth = $dbh->prepare($sql);
  my $rv = $sth->execute($user_id);

  unless ($rv) {
    error("Failed to create new session for user: $user_id", 1);
  }

  my $session_id  = get_session_id($dbh, $user_id);
  my $set_id      = get_set_id($dbh, $user_id);

  my %session = (
    id          => $session_id,
    user_id     => $user_id,
    set_id      => $set_id,
    valid       => 0,
    penalties   => 0,
    time_start  => time
  );

  return \%session;
}

sub new_set {
  my $dbh     = shift;
  my $user_id = shift;

  my $sql = 'insert into sets (user_id) values ( ? )';
  my $sth = $dbh->prepare($sql);

  my $rv = $sth->execute($user_id);

  $sth->finish;

  if ($rv) {
    return get_set_id($dbh, $user_id);
  }

  error("Failed to create new set for user: $user_id\n",1);
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

sub read_data {
  my $dbh   = shift;
  my $id    = shift;
  my $type  = shift;
  my $level = shift;

  my %data  = ();

  my $sql = "select key, val from ${type}_data
                  where ${type}_id = ? and level <= ?";
  my $sth = $dbh->prepare($sql);
  $sth->execute($id, $level);

  my $valid = 0;

  while (my $entry = $sth->fetchrow_hashref) {
    $valid = 1;
    $data{$$entry{key}} = $$entry{val};
  }

  $sth->finish;

  if ($valid) {
    return \%data;
  } else {
    error("Reading ${type}_data for ${type}_id failed", 1);
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

sub seconds_per_bpm {
  my $bpm     = shift;
  my $bpm_min = shift;
  my $bpm_max = shift;
  my $dir     = shift;

  my $min_spb = 0.5;
  my $max_spb = 1.0;

  my $percent = abs($bpm - $bpm_min) / abs($bpm_max - $bpm_min);

  # Reverse percent pace is decreasing
  if ($dir < 0) {
    $percent = 1 - $percent;
  }

  return (($max_spb - $min_spb) * $percent) + $min_spb;
}

sub set_settings {
  my $options = shift;
  my $key     = shift;
  my $val     = shift;

  my $dbh = db_connect($$options{database});
  my $user_id = get_user_id($dbh, $$options{user});

  my $set_any = read_data($dbh, $user_id, 'user', 0);
  my $set_hi  = read_data($dbh, $user_id, 'user', 1);

  $$set_hi{id} = $user_id;

  if (defined $key) {
    if (defined $$set_any{$key}) {
      if (defined $val) {
        $$set_hi{$key} = $val;
        printf "Set %s = %s\n", $key, $val;
      } else {
        printf "Value to set not supplied\n", $key, $val;
      }
    } elsif (defined $$set_hi{$key}) {
      if (defined $val) {
        if ($val > $$set_hi{$key}) {
          $$set_hi{$key} = $val;
          printf "Set %s = %s\n", $key, $val;
        } else {
          printf "Unable to set %s = %s\n", $key, $val;
        }
      } else {
        printf "Value to set not supplied\n", $key, $val;
      }
    } else {
      if (defined $val) {
        printf "Unable to set %s = %s\n", $key, $val;
      } else {
        printf "Value to set not supplied\n", $key, $val;
      }
    }
  } else {
    printf "Please supply a key and value\n";
  }

  write_data($dbh, $set_hi, 'user');

  $dbh->disconnect;
}

sub steady_beats {
  my $bpm     = shift;
  my $seconds = shift;

  my $beats = $bpm * $seconds / 60;

  return "$beats:$bpm";
}

sub twitters {
  my $options = shift;
  my $message = shift;

  my $twitter = Net::Twitter->new(
    traits              => [qw/API::RESTv1_1/],
    consumer_key        => "$$options{twitter_consumer_key}",
    consumer_secret     => "$$options{twitter_consumer_secret}",
    access_token        => "$$options{twitter_access_token}",
    access_token_secret => "$$options{twitter_access_token_secret}",
  );

  my $result = $twitter->update($message);
}

sub write_data {
  my $dbh   = shift;
  my $data  = shift;
  my $type  = shift;

  my $id = $$data{id};

  my $sql = "update ${type}_data set val = ? where key = ? and ${type}_id = ?";
  my $sql2 = "insert into ${type}_data (val, key, ${type}_id) values (?, ?, ?)";

  my $update = $dbh->prepare($sql);
  my $insert = $dbh->prepare($sql2);

  foreach my $key (keys %$data) {
    # Attempt to update the entry
    my $rv = $update->execute($$data{$key}, $key, $id);
    unless ($rv > 0) {
      # Insert if update failed.
      unless ($insert->execute($$data{$key}, $key, $id)) {
        error("Storing ${type}_data ($key: $$data{$key}) failed",-1);
      }
    }
  }

  $update->finish;
  $insert->finish;
}

sub write_script {
  my $script  = shift;
  my $session = shift;
  my @beats   = @_;

  my $tell_safe = 1;
  my $tell_fail = 1;

  my $tripped   = 0;
  my $elapsed   = 0;
  my $slow_next = $$session{slow_time};
  my $tripwire  = $$session{trip_time};

  # Reset for interleaving the commands
  if (open my $script_fh, '>', $script) {
    foreach my $beat (@beats) {
      my ($count, $bpm) = split(/:/, $beat);

      while ($count > 0) {
        if ($elapsed > $$session{goal_min}) {
          if ($$session{verbose} > 0 and $tell_safe) {
            $tell_safe = 0;
            printf $script_fh "# Minimum time reached.\n";
          }
        }

        if ($elapsed > $$session{goal_max}) {
          if ($$session{verbose} > 2 and $tell_fail) {
            $tell_fail = 0;
            printf $script_fh "# Too late...\n";
          }
        }

        if ($$session{trip_ped} and $$session{verbose} > 0) {
          if ($elapsed > $slow_next) {
            if ($$session{slow_penalty} and $$session{trip_ped}) {
              printf $script_fh "# Too slow...\n";
              $slow_next += $$session{slow_grace};
            }
          }
        }

        if ($$session{trip_on} and $$session{verbose} > 1) {
          if ($elapsed >= $$session{trip_time}) {
            if ($tripped == 0 and $$session{trip_ped} == 0) {
              $tripped = 1;
              printf $script_fh "# Tripwire tripped.\n";
            }
          }
        }

        $elapsed += 60  / $bpm;
        printf $script_fh "1 %g/4 2/8\n", $bpm;
        $count--;

      }

      if ($elapsed > $$session{time_max}) {
        last;
      }
    }

    close $script_fh;
  } else {
    error("Unable to open script ($script): $!",1);
  }
}
