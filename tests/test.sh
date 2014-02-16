#! /bin/bash

prefix="$1"
testdir="$2"

if test -z "$prefix" -o ! -x "$prefix"/bin/icecc; then
    echo Usage: "$0 <install_prefix> <testdir>"
    exit 1
fi

mkdir -p "$testdir"

skipped_tests=
chroot_disabled=

start_ice()
{
    echo -n >"$testdir"/scheduler.log
    echo -n >"$testdir"/localice.log
    echo -n >"$testdir"/remoteice1.log
    echo -n >"$testdir"/remoteice2.log
    echo -n >"$testdir"/icecc.log
    echo -n >"$testdir"/stderr.log
    "$prefix"/sbin/icecc-scheduler -p 8767 -l "$testdir"/scheduler.log -v -v -v &
    scheduler_pid=$!
    echo $scheduler_pid > "$testdir"/scheduler.pid
    ICECC_TEST_SOCKET="$testdir"/socket-localice "$prefix"/sbin/iceccd --no-remote -s localhost:8767 -b "$testdir"/envs-localice -l "$testdir"/localice.log -N localice -m 2 -v -v -v &
    localice_pid=$!
    echo $localice_pid > "$testdir"/localice.pid
    ICECC_TEST_SOCKET="$testdir"/socket-remoteice1 "$prefix"/sbin/iceccd -p 10246 -s localhost:8767 -b "$testdir"/envs-remoteice1 -l "$testdir"/remoteice1.log -N remoteice1 -m 2 -v -v -v &
    remoteice1_pid=$!
    echo $remoteice1_pid > "$testdir"/remoteice1.pid
    ICECC_TEST_SOCKET="$testdir"/socket-remoteice2 "$prefix"/sbin/iceccd -p 10247 -s localhost:8767 -b "$testdir"/envs-remoteice2 -l "$testdir"/remoteice2.log -N remoteice2 -m 2 -v -v -v &
    remoteice2_pid=$!
    echo $remoteice2_pid > "$testdir"/remoteice2.pid
    notready=
    sleep 1
    for time in `seq 1 5`; do
        notready=
        if ! kill -0 $scheduler_pid; then
            echo Scheduler start failure.
            stop_ice 0
            exit 1
        fi
        for daemon in localice remoteice1 remoteice2; do
            pid=${daemon}_pid
            if ! kill -0 ${!pid}; then
                echo Daemon $daemon start failure.
                stop_ice 0
                exit 1
            fi
            if ! grep -q "Connected to scheduler" "$testdir"/${daemon}.log; then
                # ensure log file flush
                kill -HUP ${!pid}
                grep -q "Connected to scheduler" "$testdir"/${daemon}.log || notready=1
            fi
        done
        if test -z "$notready"; then
            break;
        fi
        sleep 1
    done
    if test -n "$notready"; then
        echo Icecream not ready, aborting.
        stop_ice 0
        exit 1
    fi
    flush_logs
    grep -q "Cannot use chroot, no remote jobs accepted." "$testdir"/remoteice1.log && chroot_disabled=1
    grep -q "Cannot use chroot, no remote jobs accepted." "$testdir"/remoteice2.log && chroot_disabled=1
    if test -n "$chroot_disabled"; then
        skipped_tests="$skipped_tests CHROOT"
        echo Chroot not available, remote tests will be skipped.
    fi
}

stop_ice()
{
    check_first="$1"
    scheduler_pid=`cat "$testdir"/scheduler.pid 2>/dev/null`
    localice_pid=`cat "$testdir"/localice.pid 2>/dev/null`
    remoteice1_pid=`cat "$testdir"/remoteice1.pid 2>/dev/null`
    remoteice2_pid=`cat "$testdir"/remoteice2.pid 2>/dev/null`
    if test $check_first -ne 0; then
        if ! kill -0 $scheduler_pid; then
            echo Scheduler no longer running.
            stop_ice 0
            exit 1
        fi
        for daemon in localice remoteice1 remoteice2; do
            pid=${daemon}_pid
            if ! kill -0 ${!pid}; then
                echo Daemon $daemon no longer running.
                stop_ice 0
                exit 1
            fi
        done
    fi
    for daemon in localice remoteice1 remoteice2; do
        pid=${daemon}_pid
        if test -n "${!pid}"; then
            kill "${!pid}" 2>/dev/null
        fi
        rm -f "$testdir"/$daemon.pid
        rm -rf "$testdir"/envs-${daemon}
        rm -f "$testdir"/socket-${daemon}
    done
    if test -n "$scheduler_pid"; then
        kill "$scheduler_pid" 2>/dev/null
    fi
    rm -f "$testdir"/scheduler.pid
}

# First argument is the expected output file, if any (otherwise specify "").
# Second argument is "remote" (should be compiled on a remote host) or "local" (cannot be compiled remotely).
# Third argument is expected exit code.
# Rest is the command to pass to icecc.
# Command will be run both locally and using icecc and results compared.
run_ice()
{
    output="$1"
    shift
    remote_type="$1"
    shift
    expected_exit=$1
    shift

    reset_logs local "$@"
    echo Running: "$@"
    ICECC_TEST_SOCKET="$testdir"/socket-localice ICECC_TEST_REMOTEBUILD=1 ICECC_PREFERRED_HOST=localice ICECC_DEBUG=debug ICECC_LOGFILE="$testdir"/icecc.log "$prefix"/bin/icecc "$@" 2>>"$testdir"/stderr.log
    localice_exit=$?
    if test -n "$output"; then
        mv "$output" "$output".localice
    fi
    flush_logs
    check_logs_for_generic_errors
    if test "$remote_type" = "remote"; then
        check_log_message icecc "building myself, but telling localhost"
        check_log_error icecc "<building_local>"
    else
        check_log_message icecc "<building_local>"
        check_log_error icecc "building myself, but telling localhost"
    fi
    check_log_error icecc "Have to use host 127.0.0.1:10246"
    check_log_error icecc "Have to use host 127.0.0.1:10247"

    if test -z "$chroot_disabled"; then
        reset_logs remote "$@"
        ICECC_TEST_SOCKET="$testdir"/socket-localice ICECC_TEST_REMOTEBUILD=1 ICECC_PREFERRED_HOST=remoteice1 ICECC_DEBUG=debug ICECC_LOGFILE="$testdir"/icecc.log "$prefix"/bin/icecc "$@" 2>>"$testdir"/stderr.log
        remoteice_exit=$?
        if test -n "$output"; then
            mv "$output" "$output".remoteice
        fi
        flush_logs
        check_logs_for_generic_errors
        if test "$remote_type" = "remote"; then
            check_log_message icecc "Have to use host 127.0.0.1:10246"
            check_log_error icecc "<building_local>"
        else
            check_log_message icecc "<building_local>"
            check_log_error icecc "Have to use host 127.0.0.1:10246"
        fi
        check_log_error icecc "Have to use host 127.0.0.1:10247"
        check_log_error icecc "building myself, but telling localhost"
    fi

    reset_logs noice "$@"
    "$@" 2>>"$testdir"/stderr.log
    normal_exit=$?
    flush_logs
    check_logs_for_generic_errors
    check_log_error icecc "Have to use host 127.0.0.1:10246"
    check_log_error icecc "Have to use host 127.0.0.1:10247"
    check_log_error icecc "<building_local>"
    check_log_error icecc "building myself, but telling localhost"

    if test $localice_exit -ne $expected_exit; then
        echo "Local run exit code mismatch ($localice_exit vs $expected_exit)"
        stop_ice 0
        exit 1
    fi
    if test $localice_exit -ne $expected_exit; then
        echo "Run without icecc exit code mismatch ($normal_exit vs $expected_exit)"
        stop_ice 0
        exit 1
    fi
    if test -z "$chroot_disabled" -a "$remoteice_exit" != "$expected_exit"; then
        echo "Remote run exit code mismatch ($remoteice_exit vs $expected_exit)"
        stop_ice 0
        exit 1
    fi
    if test -n "$output"; then
        if ! diff -q "$output".localice "$output"; then
            echo "Output mismatch ($output.localice)"
            stop_ice 0
            exit 1
        fi
        if test -z "$chroot_disabled"; then
            if ! diff -q "$output".remoteice "$output"; then
                echo "Output mismatch ($output.remoteice)"
                stop_ice 0
                exit 1
            fi
        fi
    fi
    if test $localice_exit -ne 0; then
        echo "Command failed as expected."
        echo
    else
        echo Command successful.
        echo
    fi
    if test -n "$output"; then
        rm -f "$output" "$output".localice "$output".remoteice
    fi
}

make_test()
{
    # make test - actually try something somewhat realistic. Since each node is set up to serve
    # only 2 jobs max, at least some of the 10 jobs should be built remotely.
    echo Running make test.
    reset_logs remote "make test"
    make -f Makefile.test OUTDIR="$testdir" clean -s
    PATH="$prefix"/lib/icecc/bin:$PATH ICECC_TEST_SOCKET="$testdir"/socket-localice ICECC_TEST_REMOTEBUILD=1 ICECC_DEBUG=debug ICECC_LOGFILE="$testdir"/icecc.log make -f Makefile.test OUTDIR="$testdir" -j10 -s 2>>"$testdir"/stderr.log
    if test $? -ne 0 -o ! -x "$testdir"/maketest; then
        echo Make test failed.
        stop_ice 0
        exit 1
    fi
    flush_logs
    check_logs_for_generic_errors
    check_log_message icecc "Have to use host 127.0.0.1:10246"
    check_log_message icecc "Have to use host 127.0.0.1:10247"
    check_log_message_count icecc 1 "<building_local>"
    echo Make test successful.
    echo
    make -f Makefile.test OUTDIR="$testdir" clean -s
}

icerun_test()
{
    # test that icerun really serializes jobs and only up to 2 (max jobs of the local daemon) are run at any time
    echo Running icerun test.
    reset_logs local "icerun test"
    rm -rf "$testdir"/icerun
    mkdir -p "$testdir"/icerun
    for i in `seq 1 10`; do
        path=$PATH
        if test $i -eq 1; then
            # check icerun with absolute path
            testbin=`pwd`/icerun-test.sh
        elif test $i -eq 2; then
            # check with relative path
            testbin=../tests/icerun-test.sh
        elif test $i -eq 3; then
            # test with PATH
            testbin=icerun-test.sh
            path=`pwd`:$PATH
        else
            testbin=./icerun-test.sh
        fi
        PATH=$path ICECC_TEST_SOCKET="$testdir"/socket-localice ICECC_TEST_REMOTEBUILD=1 ICECC_DEBUG=debug ICECC_LOGFILE="$testdir"/icecc.log "$prefix"/bin/icerun $testbin "$testdir"/icerun $i &
    done
    timeout=100
    while true; do
        runcount=`ls -1 "$testdir"/icerun/running* 2>/dev/null | wc -l`
        if test $runcount -gt 2; then
            echo Icerun test failed, more than expected 2 processes running.
            stop_ice 0
            exit 1
        fi
        donecount=`ls -1 "$testdir"/icerun/done* 2>/dev/null | wc -l`
        if test $donecount -eq 10; then
            break
        fi
        sleep 0.1
        timeout=$((timeout-1))
        if test $timeout -eq 0; then
            echo Icerun test timed out.
            stop_ice 0
            exit 1
        fi
    done

    # check that plain 'icerun-test.sh' doesn't work for the current directory (i.e. ./ must be required just like with normal execution)
    ICECC_TEST_SOCKET="$testdir"/socket-localice ICECC_TEST_REMOTEBUILD=1 ICECC_DEBUG=debug ICECC_LOGFILE="$testdir"/icecc.log "$prefix"/bin/icerun icerun-test.sh "$testdir"/icerun 0 &
    icerun_test_pid=$!
    timeout=20
    while true; do
        if ! kill -0 $icerun_test_pid 2>/dev/null; then
            break
        fi
        sleep 0.1
        timeout=$((timeout-1))
        if test $timeout -eq 0; then
            echo Icerun test timed out.
            stop_ice 0
            exit 1
        fi
    done
    
    flush_logs
    check_logs_for_generic_errors
    check_log_error icecc "Have to use host 127.0.0.1:10246"
    check_log_error icecc "Have to use host 127.0.0.1:10247"
    check_log_error icecc "building myself, but telling localhost"
    check_log_message_count icecc 11 "<building_local>"
    check_log_message_count icecc 1 "couldn't find any"
    check_log_message_count icecc 1 "could not find icerun-test.sh in PATH."
    echo Icerun test successful.
    echo
    rm -r "$testdir"/icerun
}

reset_logs()
{
    type="$1"
    shift
    # in case icecc.log or stderr.log don't exit, avoid error message
    touch "$testdir"/icecc.log "$testdir"/stderr.log
    for log in scheduler localice remoteice1 remoteice2 icecc stderr; do
        # save (append) previous log
        cat "$testdir"/${log}.log >> "$testdir"/${log}_all.log
        # and start a new one
        echo ============== > "$testdir"/${log}.log
        echo "Test ($type): $@" >> "$testdir"/${log}.log
        echo ============== >> "$testdir"/${log}.log
        if test "$log" != icecc -a "$log" != stderr; then
            pid=${log}_pid
            kill -HUP ${!pid}
        fi
    done
}

finish_logs()
{
    for log in scheduler localice remoteice1 remoteice2 icecc stderr; do
        cat "$testdir"/${log}.log >> "$testdir"/${log}_all.log
        rm -f "$testdir"/${log}.log
    done
}

flush_logs()
{
    for daemon in scheduler localice remoteice1 remoteice2; do
        pid=${daemon}_pid
        kill -HUP ${!pid}
    done
}

check_logs_for_generic_errors()
{
    check_log_error scheduler "that job isn't handled by"
    check_log_error scheduler "the server isn't the same for job"
    check_log_error icecc "got exception "
}

check_log_error()
{
    log="$1"
    if grep -q "$2" "$testdir"/${log}.log; then
        echo "Error, $log log contains error: $2"
        stop_ice 0
        exit 1
    fi
}

check_log_message()
{
    log="$1"
    if ! grep -q "$2" "$testdir"/${log}.log; then
        echo "Error, $log log does not contain: $2"
        stop_ice 0
        exit 1
    fi
}

check_log_message_count()
{
    log="$1"
    expected_count="$2"
    count=`grep "$3" "$testdir"/${log}.log | wc -l`
    if test $count -ne $expected_count; then
        echo "Error, $log log does not contain expected count (${count} vs ${expected_count}): $3"
        stop_ice 0
        exit 1
    fi
}

rm -f "$testdir"/scheduler_all.log
rm -f "$testdir"/localice_all.log
rm -f "$testdir"/remoteice1_all.log
rm -f "$testdir"/remoteice2_all.log
rm -f "$testdir"/icecc_all.log
rm -f "$testdir"/stderr_all.log

echo Starting icecream.
stop_ice 0
start_ice
check_logs_for_generic_errors

echo Starting tests.
echo ===============

run_ice "$testdir/plain.o" "remote" 0 g++ -Wall -Werror -c plain.cpp -o "$testdir/"plain.o
run_ice "$testdir/plain.o" "remote" 0 g++ -Wall -Werror -c plain.cpp -g -o "$testdir/"plain.o
run_ice "$testdir/plain.o" "remote" 0 g++ -Wall -Werror -c plain.cpp -O2 -o "$testdir/"plain.o
run_ice "$testdir/plain.ii" "local" 0 g++ -Wall -Werror -E plain.cpp -o "$testdir/"plain.ii
run_ice "$testdir/includes.o" "remote" 0 g++ -Wall -Werror -c includes.cpp -o "$testdir"/includes.o
run_ice "$testdir/plain.o" "local" 0 g++ -Wall -Werror -c plain.cpp -mtune=native -o "$testdir"/plain.o
run_ice "$testdir/plain.o" "remote" 0 gcc -Wall -Werror -x c++ -c plain -o "$testdir"/plain.o
run_ice "" "remote" 1 g++ -c nonexistent.cpp
run_ice "" "local" 0 /bin/true

if test -z "$chroot_disabled"; then
    make_test
fi

icerun_test

if test -n "`which clang++ 2>/dev/null`"; then
    # There's probably not much point in repeating all tests with Clang, but at least
    # try it works (there's a different icecc-create-env run needed, and -frewrite-includes
    # usage needs checking).
    # Clang writes the input filename in the resulting .o , which means the outputs
    # cannot match (remote node will use stdin for the input, while icecc always
    # builds locally if it itself gets data from stdin). It'd be even worse with -g,
    # since the -frewrite-includes transformation apparently makes the debugginfo
    # differ too (although the end results work just as well). So just do not compare.
    # It'd be still nice to check at least somehow that this really works though.
    run_ice "" "remote" 0 clang++ -Wall -Werror -c plain.cpp -o "$testdir"/plain.o
    rm "$testdir"/plain.o
    run_ice "" "remote" 0 clang++ -Wall -Werror -c includes.cpp -o "$testdir"/includes.o
    rm "$testdir"/includes.o
else
    skipped_tests="$skipped_tests clang"
fi

reset_logs local "Closing down"
stop_ice 1
check_logs_for_generic_errors
finish_logs

if test -n "$skipped_tests"; then
    echo "All tests OK, some were skipped:$skipped_tests"
    echo =============
else
    echo All tests OK.
    echo =============
fi
