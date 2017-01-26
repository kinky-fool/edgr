#!/usr/bin/perl

# todo:
# finish algorithm to calculate goal
# use more functions
# test goals
# add considerations for distance from mean / std dev
# add considerations for coin flips
# determine how failure and success should affect things

use strict;
use warnings;

use edgr;

my $user_id = 42;
my $std_ttl = 10;
my $goal_offset = 2;

main();

exit;

sub main {
  my $fails = prompt("Failed coin flips");

  if ($fails =~ /[^0-9]/) {
    printf STDERR "Not a number: %s\n",$fails;
    exit 1;
  }

  my ($mean,$std_dev) = get_user_stats($user_id);
  if ($std_dev < 0.5) {
    $std_dev = 0.5;
  }
  printf "mean: %0.2f\nstd dev: %0.2f\n",$mean,$std_dev;

  my $goal      = $mean - $std_dev * $goal_offset;
  for (0 .. $fails+$goal_offset) {
    $goal += rand($std_dev);
  }
  printf "goal: %0.2f\n",$goal;

  #my $session_script = make_script($goal,$user_id,$fails);
  my $length = prompt("How long");


  my $ttl = int($std_ttl - (abs($mean - $length) / $std_dev));

  if ($ttl < 0) {
    $ttl = 0;
  }

  # Decrement sessions TTLs
  age_sessions($user_id);
  save_session($user_id,$ttl,$length,$goal,$mean,$fails);
}
