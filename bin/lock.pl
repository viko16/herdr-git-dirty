#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:flock F_SETFD);

my $path = shift @ARGV or die "missing lock file\n";
# Never unlink this file: all contenders must lock the same inode. The kernel
# releases the lock on exit, including crashes before the PID file is written.
open my $lock, '>>', $path or die "open $path: $!\n";
flock($lock, LOCK_EX | LOCK_NB) or exit 0;
# Keep the descriptor across exec so the poller itself owns its lifetime lock.
fcntl($lock, F_SETFD, 0) or die "inherit lock: $!\n";
exec @ARGV or die "exec: $!\n";
