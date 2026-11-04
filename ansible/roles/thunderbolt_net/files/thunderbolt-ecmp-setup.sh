#!/bin/bash
# Wait for both TB interfaces, turn off their offloads, and remove the old
# static ECMP (table 100).
#
# Until 2026-11-04 this script installed "ip rule from <own addr> lookup 100"
# plus static ECMP routes {direct, via the third node} into table 100. That
# breaks when the third node's onward link dies: the static "via X" nexthop
# stays, X routes the packet straight back, and the sender drops it as a
# martian (its source is the sender's own address). Unplugging pve-2<->pve-3
# that day stalled pve-1<->pve-3 for ~40 s. Routing is now left to OSPF alone,
# which reroutes in ~2 s. The script name and unit are kept so the recover
# script and existing installs keep working; the cleanup below is idempotent.

exec 200>/var/lock/thunderbolt-ecmp-setup.lock
flock -n 200 || exit 0

for i in $(seq 1 60); do
    ip -4 -o addr show tb0 2>/dev/null | grep -q 'inet ' &&
    ip -4 -o addr show tb1 2>/dev/null | grep -q 'inet ' && break
    sleep 2
done

# GSO/GRO on thunderbolt_net reorders forwarded super-packets (see
# usb4-networking-setup.md), so keep them off even when only one link is up.
for ifc in tb0 tb1; do
    ip link show "$ifc" >/dev/null 2>&1 && ethtool -K "$ifc" tso off gso off gro off 2>/dev/null
done

# Remove the legacy static ECMP if it is still there.
while ip rule show | grep -q 'lookup 100'; do
    pref_from=$(ip rule show | awk '/lookup 100/ {sub(":","",$1); print $1, $3; exit}')
    ip rule del pref ${pref_from% *} from ${pref_from#* } lookup 100 || break
done
ip route flush table 100 2>/dev/null

logger -t thunderbolt-ecmp "TB offloads set; static ECMP (table 100) absent"
