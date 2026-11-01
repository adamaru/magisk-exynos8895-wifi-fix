# Samsung Exynos 8895 Wi-Fi & Battery Drain Fix

A systemless Magisk / KernelSU / APatch module that resolves severe CPU drain, battery consumption, and Wi-Fi subsystem issues on Samsung Exynos 8895 devices running modern custom ROMs (specifically LineageOS 23.2 / Android 16).

The root cause is an impedance mismatch between legacy 2017 Samsung/Broadcom vendor Wi-Fi blobs & Linux 4.4 kernel and modern Android 16 framework components (the updated Wi-Fi Mainline Apex and NetworkStack APFv6).

---

## Supported Devices

Strictly for **Samsung Exynos 8895 (`universal8895`)** hardware platforms:
- **Samsung Galaxy S8+** (`SM-G955F`, `SM-G955FD`, `SM-G955N` / `dream2lte`)
- **Samsung Galaxy S8** (`SM-G950F`, `SM-G950FD`, `SM-G950N` / `dreamlte`)
- **Samsung Galaxy Note 8** (`SM-N950F`, `SM-N950FD`, `SM-N950N` / `greatlte`)

> **Note** North American Qualcomm Snapdragon 835 variants (`SM-G950U`, `SM-G955U`, `SM-N950U` / `dreamqlte`, `dream2qlte`, `greatqlte`) use Qualcomm Wi-Fi chipsets (WCN3990) and do not suffer from this issue. The installer automatically detects and safely aborts on any Snapdragon or non-8895 device.

---

## Problems Addressed

### 1. Broadcom WifiHAL RSSI Spin-Loop (~38% CPU Drain)
- **Root Cause**: The proprietary Broadcom Wi-Fi HAL (`libwifi-hal.so`) lacks hardware RSSI threshold interrupt support on Exynos 8895 under modern Android versions. When the framework initiates RSSI monitoring (`wifi_start_rssi_monitoring`), the driver gets trapped in an immediate, self-triggering callback loop running at over 100 Hz.
- **Impact**: `android.hardware.wifi-service` continuously pegs the CPU at 38–40%, heating the device and draining the battery rapidly during idle (up to 4% per hour).
- **Fix**: Patched `wifi_start_rssi_monitoring` entry point (offset `0x23ae8`) in `libwifi-hal.so` with `mov w0, #-3; ret` (`WIFI_ERROR_NOT_SUPPORTED`). The Android framework gracefully falls back to periodic 3-second background polling, dropping `android.hardware.wifi-service` CPU usage from ~38% to **0.0%**.

### 2. wpa_supplicant Verbose Debug Spam (~14% CPU in `logd`)
- **Root Cause**: Stock vendor init service configuration passes `-dd` (extreme debug verbosity) to `wpa_supplicant`.
- **Impact**: Constantly floods `logcat` with Wi-Fi event chatter, driving `logd` CPU consumption up to 14%.
- **Fix**: Stripped the `-dd` flag from `android.hardware.wifi.supplicant-service.rc`, restoring quiet logging and normal `logd` idle behavior.

### 3. NetworkStack APF MTU SELinux Denial & Suspend Abort Loop
- **Root Cause**: The legacy Exynos 4.4 kernel exports `/sys/devices/virtual/net/wlan0` with context `sysfs_virtual:s0`. Modern Android SELinux policy denies `com.android.networkstack.process` access to search/read `sysfs_virtual:s0`, preventing NetworkStack from querying the interface MTU and installing Android Packet Filter (APF) bytecode into the Wi-Fi hardware.
- **Impact**: Without hardware packet filtering, the Broadcom chip wakes the host CPU on every background broadcast/multicast frame (`dhdpcie_host_wake` / `wlan_oob_irq_wake` firing tens of thousands of times), aborting suspend every 800ms to 2 seconds.
- **Fix**: Injected least-privilege `sepolicy.rule` granting `network_stack` access strictly to `sysfs_net`, combined with a dual-gated boot service script (`service.sh`) that waits for `wlan0` netdev registration and persistently relabels `/sys/devices/virtual/net` to `u:object_r:sysfs_net:s0`.

---

## Safety & Incompatibility Guards

The installer script ([`customize.sh`](customize.sh)) implements a multi-tier safety guard:
1. **Architecture Guard**: Rejects anything that is not `arm64`.
2. **SoC & Platform Guard**: Inspects `ro.hardware`, `ro.boot.hardware`, `ro.product.board`, and `ro.soc.model`. Explicitly rejects Qualcomm platforms (`qcom`, `msm8998`, `*qlte*`) and non-8895 SoCs.
3. **Deterministic 32-Byte Binary Signature Matching**: Verifies the exact 32-byte target opcode sequence (`fd7bbaa9fb0b00f9fa6702a9f85f03a9f65704a9f44f05a9fd030091f403002a`) in `/vendor/lib64/libwifi-hal.so` across two full AArch64 instruction groups before applying changes. If the signature is not found or already patched, it refuses to perform blind edits and exits safely.
4. **Post-Patch Verification**: Verifies byte-for-byte size invariance, confirms target elimination, and asserts with `cmp -l` that exactly 8 bytes (the `mov w0, #-3; ret` opcode) were altered across the entire 400 KB binary before allowing installation to complete.

---

## SELinux Fix & Reversion Behavior

The SELinux fix operates completely systemlessly without modifying any system partition files on disk:

1. **`sepolicy.rule` (Live In-Memory Policy Injection)**:
   - Magisk / KernelSU injects rules dynamically into the kernel's in-memory SELinux policy (`/sys/fs/selinux/load`) during early boot.
   - The on-disk system SELinux policies (`/system/etc/selinux/`) remain 100% untouched.
   - **Reversion**: When the module is disabled or uninstalled, Magisk / KernelSU ignores `sepolicy.rule`. On the next reboot, the device boots with its original stock SELinux policy.

2. **`service.sh` (In-Memory sysfs Relabeling)**:
   - `/sys` (`sysfs`) is a volatile in-memory kernel virtual filesystem recreated from scratch in RAM on every cold boot.
   - `service.sh` runs late in the boot sequence (`chcon -R u:object_r:sysfs_net:s0 /sys/devices/virtual/net`) to grant the NetworkStack process MTU read access.
   - **Reversion**: When the module is disabled, `service.sh` does not run. On reboot, `/sys` mounts with its default kernel-assigned `sysfs_virtual:s0` labels.

---

## Module Structure

```
├── META-INF/                    # Universal recovery installer (TWRP/OrangeFox)
│   └── com/google/android/
│       ├── update-binary        # Magisk/KernelSU/APatch recovery bootstrap
│       └── updater-script       # Recovery installation placeholder (#MAGISK)
├── customize.sh                 # Multi-tier guard and dynamic in-place binary patcher
├── module.prop                  # Magisk module metadata
├── package.sh                   # Helper script to build flashable zip
├── sepolicy.rule                # Systemless SELinux policy injection for NetworkStack APF
├── service.sh                   # Late boot script relabeling /sys/devices/virtual/net
├── system/
│   └── vendor/
│       └── etc/
│           └── init/
│               └── android.hardware.wifi.supplicant-service.rc  # Stripped -dd debug flag
└── README.md
```

---

## Prerequisites

| Root Solution | Metamodule Required? | Notes |
| :--- | :---: | :--- |
| **Magisk** | No | Magisk includes built-in Magic Mount to overlay system and vendor files natively. |
| **KernelSU** |  **Yes** | KernelSU core does not include a filesystem overlay engine. A mounting metamodule is required to mount `/system` and `/vendor` modifications. |
| **APatch** |  **Yes** | APatch requires an overlay or metamodule provider to mount partition modifications. |

### Recommended Metamodule for Exynos 8895 (KernelSU / APatch)
For KernelSU or APatch on Samsung Exynos 8895 devices, **[Hybrid Mount (`meta-hybrid_mount`)](https://github.com/Hybrid-Mount/meta-hybrid_mount)** is strongly recommended:
- **Why not stock `meta-overlayfs`?**: The Exynos 8895 runs on Linux kernel 4.4. The kernel 4.4 implementation of OverlayFS has known limitations on modern Android (such as broken SELinux context inheritance and crashes when overlaying read-only vendor partitions).
- **Configuration**: Ensure Hybrid Mount is set to `magic` (bind mount) mode (`default_mode = "magic"` in `/data/adb/hybrid-mount/config.toml`).
- **Installer Guard**: The installer script automatically detects if KernelSU/APatch is present and verifies that an active mounting provider (`hybrid_mount`, `meta-overlayfs`, etc.) is installed, issuing a visible warning if none is found.

---

## Installation

### Via Custom Recovery (TWRP / OrangeFox)
1. Transfer the flashable ZIP archive to device storage or MicroSD card.
2. Boot into TWRP or OrangeFox recovery.
3. Tap **Install** -> Select the `.zip` archive -> Swipe to flash.
4. Reboot system.

### Via Magisk / KernelSU / APatch Manager
1. Download or build the module ZIP (`./package.sh`).
2. Transfer the `.zip` archive to your device.
3. Open Magisk / KernelSU / APatch manager.
4. Navigate to **Modules** -> **Install from storage** and select the ZIP file.
5. Reboot your device.

> **Note for KernelSU / Hybrid Mount users**: On Linux 4.4 kernels, ensure Hybrid Mount is set to `magic` mount mode (`default_mode = "magic"` in `/data/adb/hybrid-mount/config.toml`). Linux 4.4 does not support overlayfs SELinux context inheritance properly on Android 16.

---

## Verification

After rebooting, verify the fixes in an ADB shell or terminal emulator:

1. **Check WifiHAL CPU utilization (should be 0.0%)**:
   ```bash
   top -b -n 1 | grep wifi
   ```

2. **Check APF packet filter status (should report RUNNING)**:
   ```bash
   dumpsys wifi | grep -i "Filter update status"
   ```

3. **Check SELinux denials (should show 0 denials for network_stack)**:
   ```bash
   logcat -d | grep "avc: denied" | grep network_stack
   ```

4. **Check in-memory sysfs SELinux label (should report `sysfs_net:s0`)**:
   ```bash
   ls -ldZ /sys/devices/virtual/net
   ```

---

## Building from Source

To package the flashable ZIP archive locally:

```bash
chmod +x package.sh
./package.sh
```

The resulting zip file will be generated in `dist/exynos-8895-wifi-battery-fix-<version>.zip`.

---

## License

This project is licensed under the [MIT License](LICENSE).
No proprietary vendor binaries are distributed within this repository.
