#!/bin/bash
# What do the two unidentified firmware settings slots hold?
#
# Both are extended CMOS bytes read through WMI, and neither can be identified
# by reading the firmware: the AML stores and returns them without ever
# decoding a value. The only way to find out what an option controls is to
# change it in BIOS setup and see which byte moved.
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
# Usage: sudo bash tests/test-cmos-slots.sh
#
#   1. run it
#   2. reboot into BIOS setup (Del or F2 on Gigabyte)
#   3. change ONE option, note its name and new value
#   4. boot back, run it again -- it diffs against the previous run itself
#
# THE SCRIPT KEEPS ITS OWN HISTORY, deliberately. This test is the one that
# spans a reboot, so asking the caller to redirect output somewhere is a
# footgun: /tmp is tmpfs on this distribution and is gone exactly when the
# comparison is needed. The log lives in /var/tmp, which persists across a
# reboot by design -- that is the whole difference between it and /tmp.
#
# Read-only with respect to the firmware. Writes nothing but its own log.

set -uo pipefail

P=/sys/devices/platform/gigabyte_laptop
LOG=${GIGABYTE_CMOS_LOG:-/var/tmp/gigabyte-cmos-slots.log}

die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (debug_method is 0600)"
[ -d "$P" ] || die "driver not loaded: $P does not exist"
[ -e "$P/debug_method" ] || die "$P/debug_method is missing"

# One value per slot, trimmed to just the number the reply reports, so two runs
# can be compared without the surrounding prose getting in the way.
read_slot() {
	echo "$1" > "$P/debug_method" || { echo "READ-FAILED"; return; }
	cat "$P/debug_method"
}

E6=$(read_slot 0xE6)
A3=$(read_slot 0xA3)

# Whichever card owns the connected eDP is the one driving the panel, which is
# what the MUX selects -- the independent check on 0xE6.
panel() {
	local s c
	for s in /sys/class/drm/card*-eDP-*/status; do
		[ -e "$s" ] || continue
		[ "$(cat "$s")" = connected ] || continue
		c=$(basename "$(dirname "$s")")
		printf '%s(%s)' "$c" \
			"$(basename "$(readlink -f "/sys/class/drm/${c%%-*}/device/driver" 2>/dev/null)" 2>/dev/null)"
		return
	done
	echo "none"
}
PANEL=$(panel)

NOW=$(date -Is)
printf 'run    : %s\n' "$NOW"
printf '0xE6   : %s' "$E6"
printf '0xA3   : %s' "$A3"
printf 'panel  : %s\n' "$PANEL"

# Compare against the previous run before appending this one.
PREV=""
[ -r "$LOG" ] && PREV=$(tail -1 "$LOG")

printf '%s\t%s\t%s\t%s\n' "$NOW" "${E6//$'\n'/ }" "${A3//$'\n'/ }" "$PANEL" >> "$LOG"

echo
if [ -z "$PREV" ]; then
	cat <<-EOF
	First run -- nothing to compare against yet. Saved to $LOG.

	Now reboot into BIOS setup, change ONE option, boot back, and run this
	again. It will tell you which slot moved.
	EOF
	exit 0
fi

IFS=$'\t' read -r p_when p_e6 p_a3 p_panel <<< "$PREV"
echo "Compared against the previous run at $p_when:"

changed=0
cmp_field() {   # cmp_field <label> <before> <after>
	if [ "$2" = "$3" ]; then
		printf '  %-6s unchanged\n' "$1"
	else
		printf '  %-6s CHANGED\n    was: %s\n    now: %s\n' "$1" "$2" "$3"
		changed=$((changed + 1))
	fi
}
cmp_field 0xE6  "$p_e6"    "${E6//$'\n'/ }"
cmp_field 0xA3  "$p_a3"    "${A3//$'\n'/ }"
cmp_field panel "$p_panel" "$PANEL"

echo
if [ "$changed" -eq 0 ]; then
	cat <<-'EOF'
	Nothing moved. The option you changed lives somewhere other than these two
	slots -- try a different one, or if BIOS setup has no graphics-mode and no
	USB-charging option at all, both slots close as unresolvable. That is a real
	answer: 0xE6 then stays read-only permanently, and USB sleep charging stays
	closed with nothing depending on it.
	EOF
else
	cat <<-'EOF'
	Record which BIOS option you changed against the slot that moved, in
	CLAUDE.md under "The extended-settings slot map". A second anchored value
	for 0xE6 is what makes its encoding usable; a move in 0xA3 identifies the
	last unaccounted slot and reopens USB sleep charging as implementable.
	EOF
fi

echo
echo "Full history: $LOG"
