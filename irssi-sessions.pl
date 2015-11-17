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

  # Count the message
  $$state{messages_seen}++;

  # Adjust the percent used to determine if Icy Hot is enabled
  my $icy_chance_add_max = Irssi::settings_get_int('icy_chance_add_max');
  $$state{icy_chance} += int(rand($icy_chance_add_max)+1);

  # Increase the Icy Hot bonus
  $$state{icy_bonus} += Irssi::settings_get_int('icy_bonus');

  # Immediately increase Icy Hot active
  $$state{icy_active} += Irssi::settings_get_int('icy_prize');

  # Toggle the arming state for Icy Hot, based on messages received
  if ($$state{messages_seen} > Irssi::settings_get_int('arm_after')) {
    if (Irssi::settings_get_int('invert_arming') > 0) {
      $$state{icy_armed} = 0;
    } else {
      $$state{icy_armed} = 1;
    }
  } else {
    if (Irssi::settings_get_int('invert_arming') > 0) {
      $$state{icy_armed} = 1;
    } else {
      $$state{icy_armed} = 0;
    }
  }

  # Reduce break before Icy Hot can be used next
  if ($$state{icy_break} > 0) {
    $$state{icy_break} -= Irssi::settings_get_int('sub_icy_break');
  }

  # Reduce break before lube can be used next
  if ($$state{lube_break} > 0) {
    $$state{lube_break} -= Irssi::settings_get_int('sub_lube_break');
  }

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
Irssi::settings_add_int('sessions','invert_arming',0);
Irssi::settings_add_int('sessions','sub_icy_break',5);
Irssi::settings_add_int('sessions','sub_lube_break',3);
Irssi::settings_add_int('sessions','icy_bonus',3);
Irssi::settings_add_int('sessions','icy_prize',10);
Irssi::settings_add_int('sessions','icy_chance_add_max',5);
Irssi::settings_add_int('sessions','arm_after',1);
Irssi::settings_add_str('sessions','config_file',"$ENV{HOME}/.config/sessions");

Irssi::signal_add('message private','who_is_it');
