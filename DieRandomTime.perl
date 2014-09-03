#!/usr/bin/perl
# Michael Hiller, 2014

# script to test para.pl. Read a threshold between 0 and 1 as input. 
# Then get a random number, sleep $ARGV[0] sec, if that number is below the threshold, exit 0 otherwise exit -1. 

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
my $T = 0;
GetOptions ("T=f"  => \$T) || die "call: $0 -T float between 0 and 1\n";

die "call: $0 sleeptime -T float between 0 and 1\n" if ($T > 1 || $T < 0 || $#ARGV < 0);

srand(`echo \$RANDOM`);
my $num = rand(1);

my $sleepTime = $ARGV[0];

print "random $num  threshold $T  sleepTime $sleepTime\n";

sleep($sleepTime);

if ($num < $T) {
	exit 0;
}else{
	exit -1;
}
