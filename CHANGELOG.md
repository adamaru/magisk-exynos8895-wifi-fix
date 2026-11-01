# Changelog

All notable changes to the Samsung Exynos 8895 Wi-Fi & Battery Drain Fix module are documented here.

## [v1.0.0] - 2026-11-01

### Added
- **Broadcom WifiHAL RSSI Spin-Loop Fix**: Patched `wifi_start_rssi_monitoring` (offset `0x23ae8`) in `libwifi-hal.so` with `mov w0, #-3; ret` (`WIFI_ERROR_NOT_SUPPORTED`), dropping CPU usage from ~38% to 0.0%.
- **32-Byte Signature Verification**: Binary prologue matching verifies 32 bytes (8 full AArch64 instructions) before applying the patch, strictly asserting exactly 8 bytes modified across the entire binary.
- **wpa_supplicant Debug Suppression**: Stripped `-dd` verbose debugging flag from vendor init config to prevent `logd` churn.
- **NetworkStack APF Hardware Packet Filtering**: Systemless least-privilege SELinux rules (`sysfs_net`) and dual-gated sysfs net relabeling restoring APF bytecode compilation and deep sleep.
- **Dual-Gate Boot Service**: `service.sh` waits for `sys.boot_completed=1` and `/sys/class/net/wlan0` netdev availability before relabeling, logging to `${MODDIR}/service.log`.
- **Zero Proprietary Blobs**: Dynamic in-place on-device patching with multi-tier hardware guards (rejecting Snapdragon/non-8895 SoCs) and memory-safe 32KB chunked scanning.
- **Universal Installer**: Recovery bootstrap (`META-INF/com/google/android/`) supporting TWRP, OrangeFox, Magisk, KernelSU, and APatch.
- **Module Update Manifest**: Integrated `updateJson` pointing to GitHub release channel.
