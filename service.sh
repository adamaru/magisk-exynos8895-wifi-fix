#!/system/bin/sh
#
# Samsung Exynos 8895 Wi-Fi & Battery Fix: Boot Service
# Dual-gate sysfs relabeling service ensuring wlan0 netdev registration
# before relabeling /sys/devices/virtual/net to sysfs_net:s0.
#

MODDIR="${0%/*}"
LOG="${MODDIR}/service.log"

# Gate 1: Wait for Android boot completed
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Gate 2: Wait for wlan0 netdev interface to register in sysfs (up to 30 seconds)
i=0
while [ ! -d /sys/class/net/wlan0 ] && [ "$i" -lt 15 ]; do
    sleep 2
    i=$((i + 1))
done

# Log execution and relabel virtual net subsystem
WLAN_READY=$([ -d /sys/class/net/wlan0 ] && echo "detected" || echo "timed_out")
date "+[%Y-%m-%d %H:%M:%S] Boot completed; wlan0 interface: ${WLAN_READY} (waited ${i}x2s)" >> "$LOG" 2>&1

# Relabel sysfs net virtual tree so NetworkStack can install APF packet filter bytecode
if chcon -R u:object_r:sysfs_net:s0 /sys/devices/virtual/net >> "$LOG" 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Successfully relabeled /sys/devices/virtual/net to sysfs_net:s0" >> "$LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: chcon returned non-zero exit code" >> "$LOG"
fi
