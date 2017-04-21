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
