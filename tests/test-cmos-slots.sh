#!/bin/bash
# What do the two unidentified firmware settings slots hold?
#
# Both are extended CMOS bytes read through WMI, and neither can be identified
# by reading the firmware: the AML stores and returns them without ever
# decoding a value. The only way to find out what an option controls is to
# change it in BIOS setup and see which byte moved.
#
# That means this script has to survive a reboot, which is why it lives here
# rather than in a temporary directory.
#
#   0xE6 -> CMOS 0xD0   the display MUX. One value is anchored: 0x00 means the
#                       panel is on the integrated GPU, confirmed against the
#                       DRM connectors. The rest of the encoding is unknown and
#                       must NOT be written on a guess -- it is consumed at the
#                       next boot, so a wrong value can route the panel to a
#                       GPU whose driver is not up. Look for a BIOS option
#                       named Graphics Mode, GPU Mode, MUX Switch, Display
#                       Mode, Discrete Graphics or Hybrid.
#
#   0xA3 -> CMOS 0xD1   purpose appears NOWHERE in the firmware. It is the only
#                       unaccounted settings slot, which makes it the one lead
#                       for USB sleep charging: usb_charge_s3_toggle and _s4
#                       have no firmware method behind them, but the BIOS
#                       setting may still live here. Look for USB Charge, Power
#                       On USB, USB Power Share, Charging in S3/S4 or
#                       Always-on USB.
#
# Usage: sudo bash scripts/test-cmos-slots.sh
#
#   1. run it, keep the output
#   2. reboot into BIOS setup (Del or F2 on Gigabyte)
#   3. change ONE option, note its name and new value
#   4. boot back, run it again
#   5. whichever number moved is the slot that option lives in
#
# Read-only. Writes nothing, so it is safe to run at any time.

set -uo pipefail

P=/sys/devices/platform/gigabyte_laptop

die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (debug_method is 0600)"
[ -d "$P" ] || die "driver not loaded: $P does not exist"
[ -e "$P/debug_method" ] || die "$P/debug_method is missing"

read_method() {
	echo "$1" > "$P/debug_method" || return 1
	cat "$P/debug_method"
}

printf 'date: %s\n\n' "$(date -Is)"

printf '0xE6  display MUX  : %s' "$(read_method 0xE6)"
printf '0xA3  unknown slot : %s' "$(read_method 0xA3)"

# The independent check on 0xE6: whichever card owns the connected eDP is the
# one driving the panel, which is what the MUX selects.
echo
echo "Panel ownership, the independent check on 0xE6:"
for s in /sys/class/drm/card*-eDP-*/status; do
	[ -e "$s" ] || continue
	c=$(basename "$(dirname "$s")")
	printf '  %-20s %s\n' "$c" "$(cat "$s")"
done
for c in /sys/class/drm/card?; do
	[ -e "$c/device/driver" ] || continue
	printf '  %-20s driver=%s\n' "$(basename "$c")" \
		"$(basename "$(readlink -f "$c/device/driver")")"
done

cat <<'EOF'

Read [implemented] with its brackets. A reply that is not an integer means the
firmware has no case for that ID -- not that the value is zero.

If BIOS setup has neither kind of option, both slots close as unresolvable,
which is a real answer: 0xE6 then stays read-only permanently, and USB sleep
charging stays closed with nothing depending on it.
EOF
