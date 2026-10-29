#!/bin/bash
# Does detaching the discrete GPU work, and is it worth anything?
#
# Two questions, one mechanism. gpu_boost value 3 sends an ACPI eject request
# the kernel services with an orderly offline-and-unbind; value 4 restores the
# card and rescans the bus. What is untested is whether the out-of-tree nvidia
# driver survives that round trip -- and whether the card's idle draw is worth
# reclaiming in the first place.
#
# RUN THIS FROM A TEXT CONSOLE, NOT INSIDE A DESKTOP SESSION.
#
#   Ctrl+Alt+F3, log in, then:
#     sudo systemctl stop display-manager
#     sudo bash tests/test-dgpu-detach.sh
#     sudo systemctl start display-manager
#
# Why: on a hybrid machine the compositor holds the discrete GPU, because
# nvidia_drm.modeset=1 makes it a KMS device owning the chassis HDMI port.
# Measured on a GAMING A16 5TH, nvidia-smi reports kwin_wayland against it with
# type C+G. Detaching a GPU out from under a live compositor is the one part of
# this that can hang a session; with the session stopped nothing holds it.
#
# For the power comparison, run it on BATTERY -- on mains the battery gauge
# reports nothing useful and the measurement is skipped.
#
# Usage: sudo bash tests/test-dgpu-detach.sh
#
# Restores the GPU on every exit path, including Ctrl-C. The detach is not
# persistent either way: a reboot always brings the card back.

set -uo pipefail   # deliberately not -e: a failure must still reach the restore

P=/sys/devices/platform/gigabyte_laptop
BAT=/sys/class/power_supply/BAT1
SETTLE=6           # seconds for the eject/restore to take effect
SAMPLES=6          # battery gauge samples to average
SAMPLE_GAP=2

die() { echo "$*" >&2; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$P" ] || die "driver not loaded: $P does not exist"

# Find the ejectable GPU rather than hardcoding its address. The kernel creates
# an 'eject' attribute only for an ACPI device whose firmware provides _EJ0,
# and on this generation exactly one does -- \_SB.PCI0.GPP0.PEGP, whose
# physical node is the discrete GPU. That is both more portable than a fixed
# bus address and a precondition check in itself: no ejectable device means the
# firmware does not offer this at all.
find_dgpu() {
	local d node
	for d in /sys/bus/acpi/devices/*/; do
		[ -e "$d/eject" ] || continue
		node=$(readlink -f "$d/physical_node" 2>/dev/null) || continue
		[ -n "$node" ] && [ -e "$node" ] && { basename "$node"; return 0; }
	done
	return 1
}

DEV=$(find_dgpu) || die "no ejectable ACPI device with a PCI node -- this firmware does not offer a dGPU eject"
echo "ejectable device: $DEV"

gpu_present() { [ -e "/sys/bus/pci/devices/$DEV" ] && echo yes || echo NO; }

# Which driver, if any, is bound to it. Presence alone is not a successful
# restore: "does the out-of-tree nvidia driver survive the round trip" is the
# question this test exists to answer, and a card that comes back on the bus
# with nothing bound to it has failed that even though it is visible.
gpu_driver() {
	local d="/sys/bus/pci/devices/$DEV/driver"
	[ -e "$d" ] && basename "$(readlink -f "$d")" || echo "(unbound)"
}

DRIVER_AT_START=$(gpu_driver)

# The gauge is noisy, so average. Returns milliwatts.
draw() {
	local total=0 n=0 v
	for _ in $(seq "$SAMPLES"); do
		v=$(cat "$BAT/power_now" 2>/dev/null) || return 1
		total=$((total + v)); n=$((n + 1))
		sleep "$SAMPLE_GAP"
	done
	echo $((total / n / 1000))
}

restored=0
RESTORE_OK=1
restore() {
	[ "$restored" -eq 1 ] && return
	restored=1
	say "restoring the GPU"
	echo 4 > "$P/gpu_boost" 2>/dev/null
	sleep "$SETTLE"
	if [ "$(gpu_present)" != yes ]; then
		echo "not back yet -- trying a bus rescan"
		echo 1 > /sys/bus/pci/rescan 2>/dev/null
		sleep "$SETTLE"
	fi
	local present driver
	present=$(gpu_present)
	driver=$(gpu_driver)
	echo "dGPU present: $present   driver: $driver"

	if [ "$present" != yes ]; then
		cat <<-EOF

		RESTORE FAILED -- the card is not back on the bus.
		Try:  echo 1 > /sys/bus/pci/rescan
		A reboot always brings it back; the detach does not persist.
		EOF
		RESTORE_OK=0
	elif [ "$driver" != "$DRIVER_AT_START" ]; then
		cat <<-EOF

		RESTORE INCOMPLETE -- the card is back but the driver is not.
		  before: $DRIVER_AT_START
		  after:  $driver

		That is the real answer to this test: the eject works and the card
		returns, but the graphics driver does not re-bind on its own. Try
		  modprobe -r nvidia_drm nvidia_modeset nvidia && modprobe nvidia_drm
		or reboot. Record it -- a detach that needs a reboot to undo is a very
		different feature from one that round-trips.
		EOF
		RESTORE_OK=0
	else
		echo "  driver re-bound cleanly -- the round trip works"
	fi
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

say "preconditions"
PANEL=$(grep -l '^connected$' /sys/class/drm/card*-eDP-*/status 2>/dev/null || true)
echo "connected panel:  ${PANEL:-none found}"
echo "  The firmware refuses a detach while the panel is on the discrete GPU,"
echo "  so this must name a card whose driver is amdgpu."
echo "dGPU present:     $(gpu_driver | sed "s|^|$(gpu_present), driver |")"

# Refuse rather than advise. The earlier version printed "should be stopped
# first" and then detached anyway, which is the whole hazard this test is
# careful about everywhere else. A process holding the card loses it mid-use,
# and for a compositor that means the session.
#
# The plain Processes table is used, not --query-compute-apps: that query lists
# compute contexts only, so a process using the GPU purely for graphics is
# invisible to it. Measured here, the compositor shows as type C+G -- that
# compute context is the only reason the compute-only query caught it.
echo "processes holding it:"
command -v nvidia-smi >/dev/null || die "
nvidia-smi is not available, so whether anything is using the GPU cannot be
checked. Refusing to detach blind. Set GIGABYTE_DETACH_FORCE=1 to override."

PROCS=$(nvidia-smi 2>/dev/null | sed -n '/Processes/,$p' | tail -n +4) ||
	die "nvidia-smi failed, so the process check could not run. Refusing to detach blind.
Set GIGABYTE_DETACH_FORCE=1 to override."
echo "$PROCS" | sed 's/^/  /'

if ! printf '%s' "$PROCS" | grep -q 'No running processes found'; then
	[ "${GIGABYTE_DETACH_FORCE:-0}" = 1 ] || die "
Something is still using the discrete GPU, listed above. Detaching now takes
the card away from it -- for a compositor that means your session.

Stop it first. If you are already on a text console, the usual culprit is the
display manager:
    sudo systemctl stop display-manager

To detach anyway, knowing what it costs:
    GIGABYTE_DETACH_FORCE=1 sudo -E bash tests/test-dgpu-detach.sh"
	echo
	echo "  GIGABYTE_DETACH_FORCE=1 -- proceeding with the card in use"
fi

MEASURE=0
if [ -r "$BAT/power_now" ] && [ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)" = 0 ]; then
	MEASURE=1
	say "baseline discharge with the dGPU attached"
	BEFORE=$(draw) && echo "  ${BEFORE} mW" || { echo "  gauge unreadable"; MEASURE=0; }
else
	say "skipping the power comparison"
	echo "  On mains, so the battery gauge reports nothing useful."
	echo "  Unplug and re-run if you want the saving measured."
fi

say "detaching"
echo 3 > "$P/gpu_boost" || die "write to gpu_boost failed"
sleep "$SETTLE"
echo "dGPU present: $(gpu_present)"
echo "kernel log:"
dmesg 2>/dev/null | tail -6 | sed 's/^/  /'

if [ "$(gpu_present)" = NO ] && [ "$MEASURE" -eq 1 ]; then
	say "discharge with the dGPU detached"
	if AFTER=$(draw); then
		echo "  ${AFTER} mW"
		say "result"
		printf '  attached: %s mW\n  detached: %s mW\n  saving:   %s mW\n' \
			"$BEFORE" "$AFTER" "$((BEFORE - AFTER))"
		cat <<-'EOF'

		Under about 1 W and detaching is not worth building on -- the card's
		idle draw is already small. 3 W or more and the feature earns its
		place, because runtime D3 is not reclaiming it on its own.
		EOF
	fi
elif [ "$(gpu_present)" = yes ]; then
	echo
	echo "The card is still present, so the detach did not take effect."
	echo "Most likely the firmware refused it: check the panel line above."
fi

restore
