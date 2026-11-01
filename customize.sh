SKIPUNZIP=0

ui_print "***********************************************"
ui_print "* Samsung Exynos 8895 Wi-Fi & Battery Fix    *"
ui_print "***********************************************"

# 1. Architecture Check
if [ "$ARCH" != "arm64" ]; then
    abort "! Unsupported architecture: $ARCH (arm64 required)"
fi

# 2. Hardware / SoC Platform Validation
SOC_HW=$(getprop ro.hardware)
SOC_BOOT=$(getprop ro.boot.hardware)
SOC_BOARD=$(getprop ro.product.board)
SOC_MODEL=$(getprop ro.soc.model)
DEVICE=$(getprop ro.product.device)

# Immediately reject any Qualcomm / Snapdragon variant
case "$SOC_HW$SOC_BOOT$SOC_BOARD$SOC_MODEL$DEVICE" in
    *qcom*|*msm8998*|*qlte*)
        ui_print "! Detected Qualcomm Snapdragon platform ($DEVICE / $SOC_HW)"
        abort "! Aborting: Snapdragon devices do not use Broadcom Wi-Fi and do not need this fix."
        ;;
esac

# Require genuine Exynos 8895
IS_8895=false
case "$SOC_HW$SOC_BOOT$SOC_BOARD" in
    *8895*|*universal8895*) IS_8895=true ;;
esac
case "$SOC_MODEL" in
    *8895*) IS_8895=true ;;
esac
case "$DEVICE" in
    dreamlte|dream2lte|greatlte) IS_8895=true ;;
esac

if [ "$IS_8895" != "true" ]; then
    ui_print "! Unsupported hardware detected: $SOC_HW ($DEVICE)"
    abort "! Aborting: This fix is strictly designed for Samsung Exynos 8895 devices."
fi

ui_print "- Verified compatible Exynos 8895 device: $DEVICE"

# 3. Mounting Metamodule Verification (KernelSU / APatch)
if [ "$KSU" = "true" ] || [ "$APATCH" = "true" ]; then
    HAS_MOUNT_PROVIDER=false
    MOUNT_PROVIDER=""
    for mod in hybrid_mount meta-hybrid_mount meta-overlayfs overlayfs magic_mount magic_mount_for_ksu; do
        if [ -d "/data/adb/modules/$mod" ] || [ -d "/data/adb/modules_update/$mod" ]; then
            HAS_MOUNT_PROVIDER=true
            MOUNT_PROVIDER="$mod"
            break
        fi
    done

    if [ "$HAS_MOUNT_PROVIDER" = "true" ]; then
        ui_print "- Detected mounting provider: $MOUNT_PROVIDER"
    else
        ui_print "*****************************************************"
        ui_print "! WARNING: No mounting metamodule detected!"
        ui_print "! KernelSU/APatch requires a mounting metamodule"
        ui_print "! (such as Hybrid Mount or meta-overlayfs) to mount"
        ui_print "! modified files into /system and /vendor."
        ui_print "! "
        ui_print "! CRITICAL: Without a metamodule, libwifi-hal.so"
        ui_print "! will NOT be overlaid! Only SELinux and init"
        ui_print "! service script fixes will take effect."
        ui_print "*****************************************************"
    fi
fi

# 4. Dynamic On-Device Binary Patching (32-byte AArch64 prologue verification)
TARGET_HEX="fd7bbaa9fb0b00f9fa6702a9f85f03a9f65704a9f44f05a9fd030091f403002a"
PATCH_HEX="40008012c0035fd6fa6702a9f85f03a9f65704a9f44f05a9fd030091f403002a"
STD_OFFSET=146152

SRC_HAL="/vendor/lib64/libwifi-hal.so"
[ ! -f "$SRC_HAL" ] && SRC_HAL="/system/vendor/lib64/libwifi-hal.so"

if [ ! -f "$SRC_HAL" ]; then
    abort "! libwifi-hal.so not found on device."
fi

DEST_DIR="$MODPATH/system/vendor/lib64"
mkdir -p "$DEST_DIR"
DEST_HAL="$DEST_DIR/libwifi-hal.so"

# Extract 32 bytes directly at standard function entry point (0x23ae8)
HEX_AT_STD=$(od -An -tx1 -j "$STD_OFFSET" -N 32 "$SRC_HAL" 2>/dev/null | tr -d " \n\t\r")

if [ "$HEX_AT_STD" = "$PATCH_HEX" ]; then
    ui_print "- WifiHAL is already patched in ROM (matching 32-byte opcode context)."
    ui_print "- Mirroring active binary to module directory..."
    cp -p "$SRC_HAL" "$DEST_HAL"
elif [ "$HEX_AT_STD" = "$TARGET_HEX" ]; then
    ui_print "- Detected stock WifiHAL binary at standard offset 0x23ae8."
    ui_print "- Applying 16-byte spin-loop patch in-place (mov w0, #-3; ret)..."
    cp -p "$SRC_HAL" "$DEST_HAL"
    printf '\x40\x00\x80\x12\xc0\x03\x5f\xd6' | dd of="$DEST_HAL" bs=1 seek="$STD_OFFSET" conv=notrunc 2>/dev/null

    # Post-patch 32-byte verification
    POST_HEX=$(od -An -tx1 -j "$STD_OFFSET" -N 32 "$DEST_HAL" 2>/dev/null | tr -d " \n\t\r")
    if [ "$POST_HEX" != "$PATCH_HEX" ]; then
        abort "! Verification failed: Patched opcode not verified across 32-byte window at offset 0x23ae8."
    fi

    DIFF_COUNT=$(cmp -l "$SRC_HAL" "$DEST_HAL" 2>/dev/null | wc -l)
    if [ "$DIFF_COUNT" -ne 8 ]; then
        abort "! Verification failed: Expected exactly 8 byte alterations, found $DIFF_COUNT."
    fi

    ui_print "- Patch verified successfully: exactly 8 bytes modified across 32-byte context."
else
    # Fallback memory-safe chunked scan: scan in 32KB windows with 64-byte overlap (zero RAM buffering)
    ui_print "- Binary differs at standard offset 0x23ae8. Scanning binary safely..."
    FILE_SIZE=$(wc -c < "$SRC_HAL" 2>/dev/null || echo 0)
    CHUNK_SIZE=32768
    OFFSET=0
    FOUND_OFFSET=""
    IS_ALREADY_PATCHED=false

    while [ "$OFFSET" -lt "$FILE_SIZE" ]; do
        # Read 32KB chunk + 64 bytes overlap to catch window crossings
        CHUNK_HEX=$(od -An -tx1 -j "$OFFSET" -N 32832 "$SRC_HAL" 2>/dev/null | tr -d " \n\t\r")
        case "$CHUNK_HEX" in
            *"$PATCH_HEX"*)
                IS_ALREADY_PATCHED=true
                PREFIX="${CHUNK_HEX%%"$PATCH_HEX"*}"
                FOUND_OFFSET=$((OFFSET + (${#PREFIX} / 2)))
                break
                ;;
            *"$TARGET_HEX"*)
                PREFIX="${CHUNK_HEX%%"$TARGET_HEX"*}"
                FOUND_OFFSET=$((OFFSET + (${#PREFIX} / 2)))
                break
                ;;
        esac
        OFFSET=$((OFFSET + CHUNK_SIZE))
    done

    if [ "$IS_ALREADY_PATCHED" = "true" ]; then
        ui_print "- WifiHAL is already patched in ROM (detected at offset 0x$(printf '%x' $FOUND_OFFSET))."
        cp -p "$SRC_HAL" "$DEST_HAL"
    elif [ -n "$FOUND_OFFSET" ]; then
        ui_print "- Detected stock WifiHAL at non-standard offset (0x$(printf '%x' $FOUND_OFFSET))."
        ui_print "- Applying 16-byte spin-loop patch in-place..."
        cp -p "$SRC_HAL" "$DEST_HAL"
        printf '\x40\x00\x80\x12\xc0\x03\x5f\xd6' | dd of="$DEST_HAL" bs=1 seek="$FOUND_OFFSET" conv=notrunc 2>/dev/null

        POST_HEX=$(od -An -tx1 -j "$FOUND_OFFSET" -N 32 "$DEST_HAL" 2>/dev/null | tr -d " \n\t\r")
        if [ "$POST_HEX" != "$PATCH_HEX" ]; then
            abort "! Verification failed: Patched opcode not verified at offset 0x$(printf '%x' $FOUND_OFFSET)."
        fi

        DIFF_COUNT=$(cmp -l "$SRC_HAL" "$DEST_HAL" 2>/dev/null | wc -l)
        if [ "$DIFF_COUNT" -ne 8 ]; then
            abort "! Verification failed: Expected exactly 8 byte alterations, found $DIFF_COUNT."
        fi
        ui_print "- Patch verified successfully: exactly 8 bytes modified."
    else
        ui_print "! Unrecognized Wi-Fi HAL binary: $SRC_HAL"
        ui_print "! Expected stock 32-byte signature:   $TARGET_HEX"
        ui_print "! Expected patched 32-byte signature: $PATCH_HEX"
        ui_print "! Current bytes at 0x23ae8:           $HEX_AT_STD"
        abort "! Aborting: Binary was not recognized. Refusing blind patch."
    fi
fi

# 5. Set Permissions and SELinux Contexts
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$DEST_HAL" 0 0 0644 u:object_r:vendor_file:s0
set_perm "$MODPATH/system/vendor/etc/init/android.hardware.wifi.supplicant-service.rc" 0 0 0644 u:object_r:vendor_configs_file:s0

# Immediate activation on live system:
# Relabeling /sys/devices/virtual/net in-memory right now enables NetworkStack APF
# immediately without requiring a reboot. service.sh re-applies it persistently on cold boots.
ui_print "- Applying sysfs_net SELinux rules for immediate activation..."
chcon -R u:object_r:sysfs_net:s0 /sys/devices/virtual/net 2>/dev/null || true

ui_print "- Installation successful! Please reboot your device."
