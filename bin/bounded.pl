#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(:sys_wait_h setpgid);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $seconds = shift @ARGV;
die "usage: bounded.pl seconds command [args...]\n"
    unless defined($seconds) && $seconds > 0 && @ARGV;
my $interrupted = 0;
$SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { $interrupted = 1 };
my $pid = fork();
defined($pid) or die "fork: $!\n";
if ($pid == 0) {
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = 'DEFAULT';
    setpgid(0, 0) == 0 or die "setpgid: $!\n";
    exec @ARGV or die "exec: $!\n";
}
# Both sides set the group to close the fork/exec/signal race.
setpgid($pid, $pid);
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
while (!$interrupted && clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    if (waitpid($pid, WNOHANG) == $pid) {
        my $status = $?;
        # Also close any descendants left behind by a command that exited early.
        kill 'KILL', -$pid;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
    }
    sleep .02;
}
# Signal the whole group, including helpers and hooks that ignore TERM. Keep
# the leader unreaped until after KILL so its PID cannot be reused meanwhile.
kill 'TERM', -$pid;
sleep .1;
kill 'KILL', -$pid;
waitpid($pid, 0);
exit($interrupted ? 125 : 124);
