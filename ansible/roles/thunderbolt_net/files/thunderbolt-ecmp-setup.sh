#!/bin/bash
# Wait for both TB interfaces and apply ECMP routes.
# Extracts route commands from /etc/network/interfaces so this
# script is identical on all nodes.

exec 200>/var/lock/thunderbolt-ecmp-setup.lock
flock -n 200 || exit 0

for i in $(seq 1 60); do
    ip -4 -o addr show tb0 2>/dev/null | grep -q 'inet ' &&
    ip -4 -o addr show tb1 2>/dev/null | grep -q 'inet ' && break
    sleep 2
done

if ! ip -4 -o addr show tb0 2>/dev/null | grep -q 'inet ' ||
   ! ip -4 -o addr show tb1 2>/dev/null | grep -q 'inet '; then
    logger -t thunderbolt-ecmp "Timeout: tb0 or tb1 not ready"
    exit 1
fi

logger -t thunderbolt-ecmp "Both TB interfaces up, configuring ECMP"

ethtool -K tb0 tso off gso off gro off 2>/dev/null
ethtool -K tb1 tso off gso off gro off 2>/dev/null

# Apply ip rules (idempotent)
while IFS= read -r cmd; do
    eval "$cmd"
done < <(sed -n 's/^[[:space:]]*post-up \(ip rule add.*lookup 100.*\)/\1/p' /etc/network/interfaces)

# Apply ECMP routes
while IFS= read -r cmd; do
    eval "$cmd"
done < <(sed -n 's/^[[:space:]]*post-up \(ip route replace.*table 100.*\)/\1/p' /etc/network/interfaces)

logger -t thunderbolt-ecmp "ECMP setup complete"
