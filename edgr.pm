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
    error("could not connect to database: $!");
  return $dbh;
}

sub error {
  my $message = shift;
  printf STDERR "Error: %s\n",$message;
  exit;
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
