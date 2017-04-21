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

sub play_session {
  my $user_id = shift;

  

sub main {
  play_session($user_id);
  my ($mean,$std_dev) = get_user_stats($user_id);
  if ($std_dev < 0.5) {
    $std_dev = 0.5;
  }

  my $goal = $mean - (2 * $std_dev) + rand(4*$std_dev);

  printf "goal: %0.2f\n",$goal;

  my $session_script = make_script($goal,$user_id);
  my $length = prompt("How long");

  my $ttl = int($std_ttl - (abs($mean - $length) / $std_dev));

  if ($ttl < 0) {
    $ttl = 0;
  }

  # Decrement sessions TTLs
  age_sessions($user_id);
  save_session($user_id,$ttl,$length,$goal,$mean,$fails);
}
