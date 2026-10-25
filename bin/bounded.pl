#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(setpgid);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $seconds = shift @ARGV;
die "usage: bounded.pl seconds command [args...]\n"
    unless defined($seconds) && $seconds > 0 && @ARGV;
my $interrupted = 0;
$SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub { $interrupted = 1 };
pipe(my $reader, my $writer) or die "pipe: $!\n";
my $pid = fork();
defined($pid) or die "fork: $!\n";
if ($pid == 0) {
    close $reader;
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = 'DEFAULT';
    setpgid(0, 0) == 0 or die "setpgid: $!\n";
    # This supervisor stays the group leader until the parent finishes cleanup.
    # Reaping the command does not release the leader's PID/PGID for reuse.
    my $command = fork();
    defined($command) or die "fork command: $!\n";
    if ($command == 0) {
        close $writer;
        exec @ARGV or die "exec: $!\n";
    }
    waitpid($command, 0);
    my $status = $?;
    syswrite($writer, pack('N', $status));
    close $writer;
    sleep($seconds + 1);
    exit 0;
}
close $writer;
# Both sides set the group to close the fork/exec/signal race.
setpgid($pid, $pid);
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
my $ready = '';
vec($ready, fileno($reader), 1) = 1;
my ($result, $exit_code) = ('', 124);
while (!$interrupted && clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $readable = $ready;
    if (select($readable, undef, undef, .02) > 0) {
        my $read = sysread($reader, my $chunk, 4 - length($result));
        if (!defined($read) || $read == 0) {
            $exit_code = 125; # Supervisor failed before reporting a status.
            last;
        }
        $result .= $chunk;
        if (length($result) == 4) {
            my $status = unpack('N', $result);
            $exit_code = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
            last;
        }
    }
}
close $reader;
# Every path signals before reaping the group leader, including normal command
# completion. Kill leftover descendants so inherited stdout cannot stall awk.
if (length($result) != 4 || $interrupted) {
    kill 'TERM', -$pid;
    sleep .1;
}
kill 'KILL', -$pid;
waitpid($pid, 0);
exit($interrupted ? 125 : $exit_code);
