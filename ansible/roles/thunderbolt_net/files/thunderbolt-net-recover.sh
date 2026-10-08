#!/bin/bash
IFACE="$1"
[ -z "$IFACE" ] && exit 0

DRV=/sys/bus/thunderbolt/drivers/thunderbolt-net

# Called from udev (DEVPATH is set): re-exec detached so the carrier wait below
# does not block the udev event queue and does not get killed with the event.
if [ -n "$DEVPATH" ] && [ -z "$TB_RECOVER_DETACHED" ]; then
    systemd-run --quiet --collect --no-block \
        --unit="thunderbolt-net-recover-${IFACE}-$$" \
        --setenv=TB_RECOVER_DETACHED=1 \
        /usr/local/bin/thunderbolt-net-recover.sh "$IFACE"
    exit 0
fi

# Prevent concurrent runs for the same interface
# (also stops the rebind below from recursing via the udev add/move it causes)
exec 200>/var/lock/thunderbolt-net-recover-${IFACE}.lock
flock -n 200 || exit 0

logger -t thunderbolt-net "Recovering interface $IFACE"

# Clear stale ifupdown2 state from failed boot-time ifup
ifdown --force "$IFACE" 2>/dev/null
sleep 1

for attempt in 1 2 3; do
    if ifup --force "$IFACE" 2>/dev/null; then
        logger -t thunderbolt-net "$IFACE recovered (attempt $attempt)"
        break
    fi
    logger -t thunderbolt-net "$IFACE ifup failed (attempt $attempt)"
    sleep $((attempt * 2))
done

ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null

wait_carrier() {
    local i
    for ((i = 0; i < $1; i++)); do
        [ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" = "1" ] && return 0
        sleep 1
    done
    return 1
}

# A wedged ThunderboltIP login (peer rebooted while we were bouncing the netdev)
# leaves this side NO-CARRIER while the peer still believes it is logged in.
# A local down/up does NOT fix that -- only a logout the peer notices does, so
# unbind/rebind the driver instead of needing a bounce on the other node.
if ! wait_carrier 20; then
    TBDEV=$(basename "$(readlink -f /sys/class/net/$IFACE/device 2>/dev/null)")
    if [ -n "$TBDEV" ] && [ -e "$DRV/$TBDEV" ]; then
        logger -t thunderbolt-net "$IFACE NO-CARRIER after ifup, rebinding thunderbolt-net $TBDEV"
        echo "$TBDEV" > "$DRV/unbind" 2>/dev/null
        sleep 3
        echo "$TBDEV" > "$DRV/bind" 2>/dev/null
        # the rebind re-creates the netdev; the udev run it triggers exits on the
        # lock we hold, so finish the configuration here
        for ((i = 0; i < 10; i++)); do
            [ -e "/sys/class/net/$IFACE" ] && break
            sleep 1
        done
        ifup --force "$IFACE" 2>/dev/null
        ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null
        if wait_carrier 15; then
            logger -t thunderbolt-net "$IFACE carrier up after rebind"
        else
            logger -t thunderbolt-net "$IFACE still NO-CARRIER after rebind (peer down?)"
        fi
    else
        logger -t thunderbolt-net "$IFACE NO-CARRIER and no thunderbolt device bound (peer down?)"
    fi
fi

# Trigger ECMP route setup (waits for both TB interfaces, idempotent).
# Runs in the FOREGROUND: this script is already detached from udev, and a
# backgrounded child would be killed with the systemd-run unit's cgroup,
# leaving table 100 empty after the netdev was re-created.
/usr/local/bin/thunderbolt-ecmp-setup.sh </dev/null >/dev/null 2>&1
