#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eux
set -o pipefail

# Let's run this test only if the "memory.oom.group" cgroupfs attribute
# exists. This test is a bit too strict, since the "memory.events"/"oom_kill"
# logic has been around since a longer time than "memory.oom.group", but it's
# an easier thing to test for, and also: let's not get confused by older
# kernels where the concept was still new.

if test -f /sys/fs/cgroup/system.slice/TEST-32-OOMPOLICY.service/memory.oom.group; then
    # Run a service that is guaranteed to be the first candidate for OOM killing
    systemd-run --unit=oomtest.service \
                -p Type=exec -p OOMScoreAdjust=1000 -p OOMPolicy=stop -p MemoryAccounting=yes \
                sleep infinity

    # Trigger an OOM killer run
    echo 1 >/proc/sys/kernel/sysrq
    echo f >/proc/sysrq-trigger

    while : ; do
        STATE="$(systemctl show -P ActiveState oomtest.service)"
        [ "$STATE" = "failed" ] && break
        sleep .5
    done

    RESULT="$(systemctl show -P Result oomtest.service)"
    test "$RESULT" = "oom-kill"

    # Test that kernel OOM kills are also detected when they happen in a freshly
    # recreated cgroup, i.e. after the unit was restarted and its old cgroup was
    # pruned. Previously the last seen OOM kill counter was kept around across
    # the cgroup recreation, so that subsequent OOM kills were not detected
    # anymore, and OOMPolicy=stop/kill were not applied anymore.
    cat >/run/systemd/system/oomtest-restart.service <<'EOF'
[Service]
Type=exec
OOMPolicy=stop
MemoryMax=10M
MemorySwapMax=0
# The dd child process hits the memory limit and is killed by the kernel OOM
# killer, while the main shell survives. If the OOM kill is detected the unit
# is failed with Result=oom-kill, if it is not detected the unit keeps running
# (sleep infinity).
ExecStart=sh -c 'dd if=/dev/zero of=/dev/shm/oomtest-restart bs=1M count=100 & wait $!; rm -f /dev/shm/oomtest-restart; sleep infinity'
EOF
    systemctl daemon-reload

    for _ in 1 2 3; do
        systemctl start oomtest-restart.service

        timeout 30 bash -c 'while ! systemctl is-failed --quiet oomtest-restart.service; do sleep .5; done'
        test "$(systemctl show -P Result oomtest-restart.service)" = oom-kill

        # Wait for the unit's cgroup to be pruned before the next start, so
        # that the next round runs in a freshly created cgroup, with the
        # kernel OOM counters starting from zero again.
        timeout 30 bash -c 'while [ -e /sys/fs/cgroup/system.slice/oomtest-restart.service ]; do sleep .5; done'
        systemctl reset-failed oomtest-restart.service
    done

    rm -f /run/systemd/system/oomtest-restart.service /dev/shm/oomtest-restart
    systemctl daemon-reload
fi

touch /testok
