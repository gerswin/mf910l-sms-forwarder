#!/bin/sh
### BEGIN INIT INFO
# Provides:          adb_persist
# Required-Start:    $local_fs
# Default-Start:     2 3 4 5
# Short-Description: Force ADB USB composition at boot
### END INIT INFO

SYSFS=/sys/class/android_usb/android0

case "$1" in
  start)
    [ -d "$SYSFS" ] || exit 0
    # Wait briefly for usb gadget ready
    sleep 5
    # Toggle enable to apply new composition
    echo 0 > "$SYSFS/enable" 2>/dev/null
    echo rndis,diag,serial,mass_storage,adb > "$SYSFS/functions" 2>/dev/null
    echo 6 > "$SYSFS/usb_mode" 2>/dev/null
    echo 1 > "$SYSFS/enable" 2>/dev/null
    # Ensure adbd running
    pgrep adbd >/dev/null || /sbin/adbd &
    echo "adb_persist: usb_mode=6 functions=adb"
    ;;
  stop)
    echo 0 > "$SYSFS/enable" 2>/dev/null
    ;;
  status)
    cat "$SYSFS/functions" 2>/dev/null
    ;;
  *)
    echo "usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
