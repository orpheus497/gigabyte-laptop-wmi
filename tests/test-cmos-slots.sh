#!/bin/bash
# What do the two unidentified firmware settings slots hold?
#
# Both are extended CMOS bytes read through WMI, and neither can be identified
# by reading the firmware: the AML stores and returns them without ever
# decoding a value. The only way to find out what an option controls is to
# change it in BIOS setup and see which byte moved.
#
#   0xE6 -> CMOS 0xD0   the display MUX, and two of its values are now known:
#                       0x00 is MSHybrid (panel on the integrated GPU) and 0x01
#                       is discrete (panel on the discrete one), both confirmed
#                       against the DRM connectors and boot_vga. The BIOS option
#                       is Peripherals -> "Switchable Graphics device". Whether
#                       a third value exists is still open -- the option's own
#                       selector was never opened -- and anything beyond those
#                       two must NOT be written on a guess: it is consumed at
#                       the next boot, so a wrong value can route the panel to
#                       a GPU whose driver is not up.
#
#   0xA3 -> CMOS 0xD1   purpose appears NOWHERE in the firmware, and it is still
#                       the only unaccounted settings slot.
#
#                       It is NOT USB sleep charging. That was this slot's one
#                       lead and it is dead: BIOS setup on FB03 has no USB
#                       option of any kind, so there is no setting for it to be
#                       holding. Do not go looking for USB Charge, Power On
#                       USB, USB Power Share or Always-on USB -- they are not
#                       in the menu.
#
#                       The four options in Peripherals not yet matched to a
#                       slot are RTC Support, Wake on LAN Enable, SVM Enable
#                       and Network Stack. At most one of them is here.
#
#                       Flip WAKE ON LAN. It is a device-level toggle the
#                       firmware has to act on at boot, and nothing normally
#                       depends on it. NOT SVM: that gates AMD-V, and on a
#                       machine running VMs or hardware-accelerated containers
#                       turning it off breaks them for as long as it is off --
#                       check for kvm_amd and /dev/kvm before touching it.
#                       Network Stack is the one to skip; it is most likely
#                       stored with the other boot settings.
#
#                       Nothing depends on identifying this slot.
#
# Usage: sudo bash tests/test-cmos-slots.sh
#
#   1. run it
#   2. reboot into BIOS setup (Del or F2 on Gigabyte)
#   3. change ONE option. Write down its name AND its original value --
#      nothing here can undo a BIOS change, so that note is the only way back
#   4. boot back, run it again -- it diffs against the previous run itself
#   5. to test a FURTHER option, restore the first one and RUN IT AGAIN before
#      changing the next. Never restore one and change another in the same
#      visit: the next reading would then reflect both changes, so a byte that
#      moves cannot be pinned to either -- and restoring the first one is
#      itself a change. Two reboots per option, not one.
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

# A failed read must stop the run, not log a placeholder. Appending "READ-FAILED"
# to the history would put a line in the log that the next run compares against
# and reports as a change, inventing a result from a broken read.
read_slot() {
	echo "$1" > "$P/debug_method" 2>/dev/null ||
		die "could not write $1 to $P/debug_method"
	cat "$P/debug_method" 2>/dev/null ||
		die "could not read back $P/debug_method after writing $1"
}

E6=$(read_slot 0xE6) || exit 1
A3=$(read_slot 0xA3) || exit 1
[ -n "$E6" ] && [ -n "$A3" ] || die "a slot read came back empty; refusing to log a partial result"

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
printf '0xE6   : %s\n' "$E6"
printf '0xA3   : %s\n' "$A3"
printf 'panel  : %s\n' "$PANEL"

# Compare against the previous run before appending this one.
PREV=""
[ -r "$LOG" ] && PREV=$(tail -1 "$LOG")

# A failed append must stop the run. Otherwise it reports "saved to $LOG"
# having saved nothing, and the next run compares against stale history and
# calls a real change unchanged -- or an old change new.
printf '%s\t%s\t%s\t%s\n' "$NOW" "${E6//$'\n'/ }" "${A3//$'\n'/ }" "$PANEL" >> "$LOG" ||
	die "could not append to $LOG -- the comparison this test depends on needs
that history, so nothing was saved and the run is stopped. Check the path is
writable, or point GIGABYTE_CMOS_LOG somewhere that is."

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
	Nothing moved. There are two reasons that happens, and this script cannot
	tell them apart -- it only sees the bytes:

	  (a) You did not change a BIOS option between the two runs. Then this is
	      simply a fresh BASELINE and there is nothing to read into it. That
	      is the normal case when capturing a reading before a reboot.

	  (b) You DID change one, and it is stored somewhere other than these two
	      slots -- plain NVRAM rather than this CMOS block. That is the
	      expected result for most options: only one slot is unaccounted for
	      and four options in Peripherals are unmatched, so at most one of the
	      four is here.

	If (b): BEFORE TRYING ANOTHER, put the one you just changed back -- and
	take a reading in between. That reading is not optional bookkeeping; it is
	what makes the next result attributable.

	  1. note its ORIGINAL value before you touch it, every time
	  2. reboot into setup and RESTORE it -- restore only, change nothing else
	  3. run this script again. This is the clean baseline for the next test
	  4. reboot into setup and change the NEXT option
	  5. run this script again and read the verdict

	DO NOT restore one option and change the next in the same BIOS visit.
	That is one reboot cheaper and it ruins the result: the following reading
	then reflects BOTH changes at once, so if restoring the first option moves
	the byte, the move is reported against the second option. An earlier
	version of these instructions did exactly that and claimed the single
	reading could serve as both the restored baseline and the next test's
	"before". It cannot -- a reading taken after two changes cannot be
	attributed to either of them.

	So each option costs two reboots, not one. That is the price of a result
	you can trust, and it is the same reason this test changes one thing at a
	time at all. It also means an interrupted run leaves the machine in a
	state you wrote down rather than one you have to reconstruct -- nothing in
	this script can undo a BIOS change for you, so the note is the only
	restore mechanism there is.

	Order: Wake on LAN first -- it is a toggle the firmware acts on at boot and
	nothing normally depends on it. RTC Support second. Avoid SVM if you run
	VMs or accelerated containers: it gates AMD-V and breaks them while off.

	If all four come back unchanged, 0xD1 closes as unidentifiable from the
	menu, which is a real answer and costs nothing: no feature depends on it.
	EOF
else
	cat <<-'EOF'
	Record which BIOS option you changed against the slot that moved, in
	CLAUDE.md under "The extended-settings slot map".

	First make sure exactly ONE option changed since the previous reading. If
	that reading followed a visit where you both restored one option and
	changed another, this move cannot be pinned to either of them -- take a
	restore-only reading and start the next test from it.

	A third anchored value for 0xE6 completes the MUX encoding -- 0x00 and 0x01
	are already known. A move in 0xA3 finally names the last unaccounted slot,
	which is a curiosity rather than a feature: USB sleep charging is closed
	separately, by the menu having no USB option at all.
	EOF
fi

echo
echo "Full history: $LOG"
