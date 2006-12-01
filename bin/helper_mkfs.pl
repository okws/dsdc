#!/usr/bin/perl

use strict;
my @dirs = qw [ 0 1 2 3 4 5 6 7 8 9 a b c d e f ];


sub mkfs {
    my ($lev) = @_;
    return if $lev-- == 0;
    foreach my $d (@dirs) {
	mkdir ($d);
	chdir ($d);
	mkfs ($lev);
	chdir ("..");
    }
}

if ($#ARGV != 1) {
    warn "usage: $0 <dir> <levels>\n";
    exit (1);
}

my $dir = $ARGV[0];
my $levels = $ARGV[1];

unless (-d $dir) {
    warn "Cannot access directory $dir...\n";
    exit (1);
}

chdir ($dir);
mkfs ($levels);

