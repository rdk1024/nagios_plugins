#!/usr/bin/perl -w
# BSD Licenced
# Copyright (c) 2009, Daniel Siechniewicz (daniel@siechniewicz.com)
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#     * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#     * Neither the name of the author nor the names of its contributors may be
#     used to endorse or promote products derived from this software without
#     specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings FATAL => 'all';

use Net::SNMP;
use Getopt::Long;
use vars qw($opt_P $opt_h $opt_H $opt_W $opt_C $opt_p $opt_w $opt_c $opt_t $verbose $opt_2 $opt_f $opt_s $opt_i);

$ENV{'PATH'}='';
$ENV{'BASH_ENV'}='';
$ENV{'ENV'}='';

my $snmp_version = 1;

# OID table/range we're going to use here
my $oid_table = '.1.3.6.1.4.1.2021.9.1';

my %STATUSCODE = (
    'OK'    => '0',
    'WARNING'   => '1',
    'CRITICAL'  => '2',
    'UNKNOWN'   => '3',
    );

# Help message
sub print_help {
  print <<EOT
check_disk_snmp - this script monitors diskspace and inode usage via snmp.
You need "includeAllDisks <number>%" directive in your snmpd.conf. (substitute
number 1-99 for <number>, but this value has no meaning for this script)
Basic usage:
  check_disk_snmp -H hostname
Advanced usage:
  check_disk_snmp -H hostname -p community -w 88 -c 93 -W 78 -C 87 -P 162 -t 20 -v
Available options:
         -H <hostname|ip> | --hostname=<hostname|ip>
    your monitored host (required)
         -p community | --community=<community>
    your snmp community (default: public)
         -P <number> | --port=<number>
    snmp port number (default: 161)
         -T <number> | --timeout=<number> (default: 15)
    timeout - die after this many seconds
         -h | --help
    print this help message
         -w <number|number%> | --warning=<number|number%>
    diskspace usage warning threshold (default: 90)
         -c <number|number%> | --critical=<number|number%>
    diskspace usage critical threshold (default: 95)
         -W <number|number%> | --inodewarn=<number|number%>
    inode usage warning threshold (default: 90)
         -C <number|number%> | --inodecrit=<number|number%>
    inode usage critical threshold (default: 95)
         -v | --verbose
    print additional information
         -2 | --v2c
    use snmp v2c (default: v1)
         -f | --perfdata
    add performance output
         -s <y|n> | --space <y|n>
    check disk space (default: y)
         -i <y|n> | --inodes <y|n>
    check inodes (default: y)
EOT

}


sub usage {
  my $format=shift;
  printf($format,@_);
  exit $STATUSCODE{'UNKNOWN'};
}

# Process options
Getopt::Long::Configure('bundling');
GetOptions (
  "v"   => \$verbose, "verbose"   => \$verbose,
  "P=s" => \$opt_P, "port=s"      => \$opt_P,
  "T=s" => \$opt_t, "timeout=s"   => \$opt_t,
  "h"   => \$opt_h, "help"        => \$opt_h,
  "w=s" => \$opt_w, "warning=s"   => \$opt_w,
  "c=s" => \$opt_c, "critical=s"  => \$opt_c,
  "W=s" => \$opt_W, "inodewarn=s" => \$opt_W,
  "C=s" => \$opt_C, "inodecrit=s" => \$opt_C,
  "p=s" => \$opt_p, "community=s" => \$opt_p,
  "H=s" => \$opt_H, "hostname=s"  => \$opt_H,
  "2"   => \$opt_2, "v2c"         => \$opt_2,
  "f"   => \$opt_f, "perfdata"    => \$opt_f,
  "s=s" => \$opt_s, "space=s"     => \$opt_s,
  "i=s" => \$opt_i, "inodes=s"    => \$opt_i,
  );

if ($opt_h) {print_help(); exit $STATUSCODE{'OK'};}

# SNMP version
if ($opt_2) {$snmp_version = 2;}

# Options checking

# Hostname is required
($opt_H) || ($opt_H = shift) || usage("Host name not specified\n");
my $hostname = $1 if ($opt_H =~ /^([-.A-Za-z0-9]+\$?)$/);
($hostname) || usage("Invalid host: $opt_H\n");

# Community
($opt_p) || ($opt_p = shift) || ($opt_p = "public");
my $community = $1 if ($opt_p =~ /(.*)/);

# Check disk space
($opt_s) || ($opt_s = 'y');
my $check_space = (lc($opt_s) eq 'y');

my $diskspace_warn;
my $diskspace_crit;
if ($check_space) {
    # Diskspace warning threshold
    ($opt_w) || ($opt_w = shift) || ($opt_w = 90);
    $diskspace_warn = $1 if ($opt_w =~ /^([0-9]{1,2}|100)\%?$/);
    ($diskspace_warn) || usage("Invalid diskspace warning threshold: $opt_w\n");

    # Diskspace critical threshold
    ($opt_c) || ($opt_c = shift) || ($opt_c = 95);
    $diskspace_crit = $1 if ($opt_c =~ /^([0-9]{1,2}|100)\%?$/);
    ($diskspace_crit) || usage("Invalid diskspace critical threshold: $opt_c\n");
}

# Check inodes
($opt_i) || ($opt_i = 'y');
my $check_inodes = (lc($opt_i) eq 'y');

my $inodes_warn;
my $inodes_crit;
if ($check_inodes) {
    # Inode warning threshold
    ($opt_W) || ($opt_W = shift) || ($opt_W = 90);
    $inodes_warn = $1 if ($opt_W =~ /^([0-9]{1,2}|100)\%?$/);
    ($inodes_warn) || usage("Invalid inode warning threshold: $opt_W\n");

    # Inode critical threshold
    ($opt_C) || ($opt_C = shift) || ($opt_C = 95);
    $inodes_crit = $1 if ($opt_C =~ /^([0-9]{1,2}|100)\%?$/);
    ($inodes_crit) || usage("Invalid inode critical threshold: $opt_C\n");
}

# Snmp port
($opt_P) || ($opt_P = shift) || ($opt_P = 161);
my $snmp_port = $1 if ($opt_P =~ /^([0-9]{1,5})$/ && $opt_P < 65535);
($snmp_port) || usage("Invalid snmp port: $opt_P\n");

# Timeout
($opt_t) || ($opt_t = shift) || ($opt_t = 15);
my $timeout = $1 if ($opt_t =~ /^([0-9]{1,3})$/);
($timeout) || usage("Invalid timeout value: $opt_t\n");

usage("Diskspace warning threshold: $opt_w greater or equal critical "
    . "threshold: $opt_c\n")  if ($check_space) && ($opt_w >= $opt_c);
usage("Inode warning threshold: $opt_W greater or equal critical "
    . "threshold: $opt_C\n")  if ($check_inodes) && ($opt_W >= $opt_C);

my $state = 'OK';

# Set up timeout in case something goes wrong
$SIG{'ALRM'} = sub {
  print "ERROR: No snmp response from $hostname (sigALRM)\n";
  exit($STATUSCODE{"UNKNOWN"});
};

alarm($timeout);

# Initiate snmp session
my ($session, $error) = Net::SNMP->session(
  -hostname  => $hostname,
  -port      => $snmp_port,
  -community => $community,
  -version   => $snmp_version,
);

# Return unknown if unsuccessful
if (!defined $session) {
  printf "UNKNOWN: %s.\n", $error;
  exit($STATUSCODE{"UNKNOWN"});
}

# Read whole table. Could be optimized to only get subtables
# needed (2, 3, 9, 10)
my $result = $session->get_table(
                          -baseoid => $oid_table,
                       );

# Return uknown if there's no snmp query result
if (!defined $result) {
  printf "UNKNOWN: %s.\n", $session->error();
  $session->close();
  exit($STATUSCODE{"UNKNOWN"});
}

my @real_disks;

# Iterate over fstype (sub)table and exclude certain fstypes
# Tested on Debian, RedHat and FreeBSD, you might need to add
# more(!).
foreach my $oid (keys %$result) {
  #print "OID: $oid\n";
  if ( $oid =~ /^\Q$oid_table.3.\E/ ) {
    push @real_disks, $oid unless $$result{$oid} =~
      /^(?:none|sunrpc|usbfs|nfsd|proc|devpts|udev|sysfs|devfs|rpc_pipefs|binfmt_misc|fusectl|beancounter|container|fairsched|gvfs-fuse-daemon)$/;
  }
}

my %disk_h;

# Iterate over real disks now, extracting path, diskspace and inodes utilization, etc.
foreach my $disk_oid (@real_disks) {

  (my $path_oid = $disk_oid) =~ s/^\Q$oid_table.3.\E/$oid_table.2./;
  (my $diskspace_oid = $disk_oid) =~ s/^\Q$oid_table.3.\E/$oid_table.9./;
  (my $inode_oid = $disk_oid) =~ s/^\Q$oid_table.3.\E/$oid_table.10./;
  (my $index = $disk_oid ) =~ s/^.*\.//g;

  my $status = 'UNKNOWN';
  my $status_string = 'Disk: ' . $$result{$path_oid} .' ';
  my $perfdata = '';

  if ($check_space) {
      if ($$result{$diskspace_oid} >= $diskspace_crit) {
	  $status = 'CRITICAL';
	  $status_string .= 'diskpace crit: ' . $$result{$diskspace_oid} . '%';
      } elsif ($$result{$diskspace_oid} >= $diskspace_warn) {
	  $status = 'WARNING';
	  $status_string .= 'diskpace warn: ' . $$result{$diskspace_oid} . '%';
      } else {
	  $status = 'OK';
	  $status_string .= 'diskspace ok';
      }

      $perfdata .= $$result{$path_oid} . "_(space)" . "=" . $$result{$diskspace_oid}
                  . "%" . ";" . $diskspace_warn . ";" . $diskspace_crit
                  . ";0;100";
  }

  if ($check_inodes) {
      if ($check_space) {
	  $status_string .= ', ';
      }
      if ($$result{$inode_oid} >= $inodes_crit) {
	  $status = 'CRITICAL';
	  $status_string .= 'inodes crit: ' . $$result{$inode_oid} ."%";
      } elsif ($$result{$inode_oid} >= $inodes_warn) {
	  $status = 'WARNING' unless ( $status eq 'CRITICAL' );
	  $status_string .= 'inodes warn: ' . $$result{$inode_oid} . "%";
      } else {
	  $status = 'OK';
	  $status_string .= "inodes ok";
      }

      $perfdata .= " " . $$result{$path_oid} . "_(inodes)" . "="
                  . $$result{$inode_oid} . "%" . ";" . $inodes_warn
                  . ";" . $inodes_crit . ";0;100";
  }

  $status_string .= ".\n";

  %{$disk_h{$index}} = (
    'path'           => $$result{$path_oid},
    'dev'            => $$result{$disk_oid},
    'status'         => $status,
    'status_string'  => $status_string,
    'perfdata'       => $perfdata,
      );

  if ($check_space) {
      $disk_h{$index}{'diskspace_used'} = $$result{$diskspace_oid};
  } else {
      $disk_h{$index}{'diskspace_used'} =  'Not checked';
  }

  if ($check_inodes) {
      $disk_h{$index}{'inodes_used'} = $$result{$inode_oid};
  } else {
      $disk_h{$index}{'inodes_used'} =  'Not checked';
  }
}

my $state_string;
my $perf_string;

foreach my $disk (sort {$a <=> $b} (keys(%disk_h))) {
  $perf_string .= $disk_h{$disk}{'perfdata'} . " ";
  next if (!$verbose && $disk_h{$disk}{'status'} =~ /^OK$/ );
  $state = $disk_h{$disk}{'status'} unless ($state eq 'CRITICAL');
  $state_string .= $disk_h{$disk}{'status_string'};
}

print $state . ": ";
print $state_string || "All disks within limits";
if ($opt_f) {
  print '|' . $perf_string;
  print "\n";
}
exit $STATUSCODE{$state};
