use Irssi;
use POSIX; # For POSIX::_exit
#use utime; # For utime()
use strict;
use warnings;
use vars qw($VERSION %IRSSI);

$VERSION = '0.1';
%IRSSI = (
    authors     =>  'kinky fool',
    contact     =>  'kinky.trees@gmail.com',
    name        =>  'Sessions to chat interface',
    description =>  'Interact with and modify running sessions',
    license     =>  'GPL',
    url         =>  'http://github.com/kinky-fool'
);

sub add_icy_time {
  my $add_icy_time = Irssi::settings_get_int('add_icy_time');
  my $icy_enabled = '/tmp/icy_enabled';

  if (! -e "$icy_enabled") {
    if (open FILE,'>',"$icy_enabled") {
      printf FILE "1\n";
      close FILE;
    } else {
      Irssi::print("Unable to write to $icy_enabled");
      return;
    }
  }
  my $new_time = time + $add_icy_time;
  my @info = stat("$icy_enabled");
  if ($info[9] > time) {
    $new_time = $info[9] + $add_icy_time;
  }
  utime($new_time,$new_time,"$icy_enabled");
  return;
}

sub adjust_time {
  my $file = shift;
  my $setting = shift;

  my $time = Irssi::settings_get_int($setting);
  if ($time != /^[-0-9]+$/) {
    Irssi::print("Error: Is $setting set properly?");
    return;
  }

  if (-e "$file") {
    my @info = stat("$file");
    my $setting = 'sub_lube';
    my $subtract = Irssi::settings_get_int($setting);
    utime($info[9] - $time, $info[9] - $time, "$file");
  } else {
    Irssi::print("File does not exist: $file");
  }
  return;
}


sub owner_checkin {
  my $owner = shift;

  my $last_icy    = '/tmp/last_icy';
  my $last_lube   = '/tmp/last_lube';
  my $add_pics    = '/tmp/icy-add-pics';

  my $pics_to_add = Irssi::settings_get_int('pics_to_add');
  my $pic_count = 0;

  if (open FILE,'<',"$add_pics") {
    chomp($pic_count = <FILE>);
    close FILE;
  } else {
    # New file?
    $pic_count = 0;
  }

  if (open FILE,'>',"$add_pics") {
    printf FILE "%i\n", $pic_count + $pics_to_add;
    close FILE;
  } else {
    Irssi::print("Unable to open for write: $add_pics");
  }

  add_icy_time();
  adjust_time("$last_lube",'sub_lube');
  adjust_time("$last_icy",'sub_icy');

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
        owner_checkin($owner);
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
Irssi::settings_add_int('sessions','sub_icy',60);
Irssi::settings_add_int('sessions','sub_lube',30);
Irssi::settings_add_int('sessions','pics_to_add',3);
Irssi::settings_add_int('sessions','add_icy_time',120);

Irssi::signal_add('message private','who_is_it');
