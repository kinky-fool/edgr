use Irssi;
use POSIX; # For POSIX::_exit
#use utime; # For utime()
use strict;
use warnings;
use vars qw($VERSION %IRSSI);

use Sessions;

$VERSION = '0.2';
%IRSSI = (
    authors     =>  'kinky fool',
    contact     =>  'kinky.trees@gmail.com',
    name        =>  'Sessions to chat interface',
    description =>  'Interact with and modify running sessions',
    license     =>  'GPL',
    url         =>  'http://github.com/kinky-fool'
);

sub owner_message {
  # TODO custom stuff per message or owner
  my $owner   = shift;
  my $msg     = shift;

  my $config_file = Irssi::settings_get_str('config_file');
  my $config      = read_config($config_file);

  # Bail if a state isn't 'detected'
  return unless (-f $$config{state_file});

  my $state       = set_state($$config{state_file});

  # Adjust the percent used to determine if Icy Hot is enabled
  my $icy_chance_add_max = Irssi::settings_get_int('icy_chance_add_max');
  $$state{icy_chance} += int(rand($icy_chance_add_max)+1);

  # Increase the Icy Hot bonus
  $$state{bonus_rank} += Irssi::settings_get_int('add_rank');

  # Immediately increase Icy Hot active
  $$state{bonus_active} += Irssi::settings_get_int('add_active');

  $$state{icy_armed} = toggle_bool($$state{icy_armed});
  if ($$state{messages_seen} > Irssi::settings_get_int('lock_after')) {
    # Toggle back
    $$state{icy_armed} = toggle_bool($$state{icy_armed});
  }

  # Reduce break before Icy Hot can be used next
  if ($$state{bonus_break} > 0) {
    $$state{bonus_break} -= Irssi::settings_get_int('sub_break');
  }

  # Reduce break before lube can be used next
  if ($$state{prize_break} > 0) {
    $$state{prize_break} -= Irssi::settings_get_int('sub_break');
  }

  # Count the message
  $$state{messages_seen}++;

  write_config($$state{state_file},$state);
  return;
}

sub who_is_it {
  my $server  = shift;
  my $msg     = shift;
  my $nick    = shift;
  my $address = shift;

  # Return if we are not connected to a server
  if (!$server) {
    return;
  }

  my $owners = Irssi::settings_get_str('owners');

  foreach my $owner (split(/:/,$owners)) {
    if ($nick =~ /^$owner$/i) {
      my $pid = fork();
      if (!defined($pid)) {
        Irssi::print('Error: Cannot fork() - aborting');
        return;
      }
      if ($pid == 0) {
        # Child process; do work
        owner_message($owner,$msg);
        # This is important to exit child properly.
        POSIX::_exit(1);
      } else {
        Irssi::pidwait_add($pid);
        return;
      }
    }
  }
}

Irssi::settings_add_str('sessions','owners','God:Satan');
Irssi::settings_add_int('sessions','sub_break',2);
Irssi::settings_add_int('sessions','add_rank',2);
Irssi::settings_add_int('sessions','add_active',4);
Irssi::settings_add_int('sessions','icy_chance_add_max',5);
Irssi::settings_add_int('sessions','lock_after',5);
Irssi::settings_add_str('sessions','config_file',"$ENV{HOME}/.config/sessions");

Irssi::signal_add('message private','who_is_it');
