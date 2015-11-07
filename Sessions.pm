package Sessions;

use strict;
use Exporter;
use IPC::SharedMem;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $DEBUG);

$VERSION      = 0.1;
$DEBUG        = 0;
@ISA          = qw(Exporter);
@EXPORT       = qw(fuzzy plus_or_minus read_conf write_conf
                  sec_to_human error_msg debug_msg);
@EXPORT_OK    = @EXPORT;

sub error_msg {
  # Standardize error messages
  my $message = shift;
  # 0 is a non-fatal error, non-zero will exit with that error
  my $err_lvl = shift || 0;
  if ($err_lvl =~ /[^0-9]/) {
    printf STDERR "Error: err_lvl '%s' not understood; exiting\n",$err_lvl;
    $err_lvl = 1;
  }

  printf STDERR "Error: %s\n",$message;
  if ($err_lvl != 0) {
    exit $err_lvl;
  }
  return undef;
}

sub debug_msg {
  # Standardize debug messages
  my $message = shift;

  if ($DEBUG) {
    printf "DEBUG: %s\n",$message;
  }
  return undef;
}

sub read_conf {
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

      my ($option,$value) = split(/\ /,$line,2);
      if (defined $options{$option}) {
        $options{$option} = join(':',$options{$option},split(/ /,$value));
      } else {
        $options{$option} = $value;
      }
    }
    close $conf_fh;
  } else {
    error_msg("Unable to open $conf_file: $!",1);
  }

  return \%options;
}

sub write_conf {
  my $conf_file   = shift;
  my $options     = shift;

  if (open my $conf_fh,'>',"$conf_file") {
    foreach my $option (keys %$options) {
      my $value = $$options{$option};
      $value =~ s/:/ /g;
      printf $conf_fh "%s %s\n", $option, $value;
    }
  } else {
    error_msg("Unable to open $conf_file: $!",2);
  }

  return 1;
}

sub fuzzy {
  my $num   = shift;

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

  my $result = $num;

  for (1 .. int($num)) {
    if (!int(rand($skew))) {
      if (int(rand($lean))) {
        $result += $point;
      } else {
        $result += ($point * -1);
      }
    }
  }
  return $result;
}

sub plus_or_minus {
  my $num     = shift;

  my $result  = 0;

  for (1 .. int($num)) {
    if (int(rand(2))) {
      $result += int(rand(2));
    } else {
      $result -= int(rand(2));
    }
  }

  return $result;
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

1;
