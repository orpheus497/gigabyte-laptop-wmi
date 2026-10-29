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
#     systemctl --user stop graphical-session.target     # no sudo
#     sudo bash tests/test-dgpu-detach.sh
#     sudo systemctl start display-manager               # desktop back
#
# NOT `systemctl stop display-manager`. That is the obvious command and it does
# not work on a systemd user session: it stops the login greeter while the
# session's own units carry on under user@1000.service. Measured on a GAMING
# A16 5TH -- display-manager went inactive, the session went to "closing", and
# kwin_wayland kept the card at an unchanged PID. The compositor is a user
# service (plasma-kwin_wayland.service, PartOf graphical-session.target), so
# the user target is what ends it.
#
# If the preconditions refuse, the message names the exact unit to stop, read
# from the holding PID's own cgroup rather than guessed -- so follow that in
# preference to the line above, which is only the common case.
#
# Why any of this matters: on a hybrid machine the compositor holds the
# discrete GPU, because nvidia_drm.modeset=1 makes it a KMS device owning the
# chassis HDMI port, and nvidia-smi reports kwin_wayland against it as type
# C+G. Detaching a GPU out from under a live compositor is the one part of this
# that can hang a session; with the session stopped nothing holds it.
#
# For the power comparison, run it on BATTERY -- on mains the battery gauge
# reports nothing useful and the measurement is skipped.
#
# BEFORE YOU RUN THIS: ON A GAMING A16 5TH IT COSTS A REBOOT.
#
# Measured 29 Oct 2026. The eject is serviced -- nvidia-drm removes the device
# and unloads -- but the card stays on the PCI bus with a non-zero usage count,
# leaving it present-but-unbound. Every in-session recovery then fails:
# gpu_boost 4 aborts in firmware on an unresolved PEGP._ON, a PCI rescan is a
# no-op because nothing left the bus, modprobe -r is refused on a stuck
# refcount, and writing the driver's bind file HANGS UNINTERRUPTIBLY in D
# state. Only a reboot clears it.
#
# So this is a one-shot diagnostic, not a feature you can exercise casually.
# Run it when you want the answer re-confirmed on different firmware, and
# expect to reboot afterwards.
#
# Usage: sudo bash tests/test-dgpu-detach.sh
#
# It ATTEMPTS a restore on every exit path, including Ctrl-C, and on this
# firmware that attempt fails -- gpu_boost 4 cannot run. Nothing is left
# half-written and the detach is not persistent, so a reboot always brings the
# card back; it is just that a reboot is the only thing that does.

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
DETACHED=0            # set to 1 only once the eject has actually been written
restore() {
	[ "$restored" -eq 1 ] && return
	restored=1

	# If no detach was ever attempted -- the preconditions refused, or the
	# user interrupted before that point -- there is nothing to put back and
	# writing gpu_boost 4 is NOT harmless. On this firmware it takes the
	# PEGP._ON() branch whenever the card is attached, and that symbol does
	# not resolve: the whole WMBD method aborts with AE_NOT_FOUND. An earlier
	# version restored unconditionally and then reported "the round trip
	# works" about a round trip that never happened.
	if [ "$DETACHED" -eq 0 ]; then
		say "nothing was detached -- not writing the restore"
		echo "  The GPU was never ejected, so gpu_boost 4 is not sent. It is"
		echo "  not a no-op on this firmware: with the card attached it hits"
		echo "  PEGP._ON(), which is an unresolved External here, and aborts"
		echo "  WMBD with an ACPI BIOS Error in dmesg."
		printf '  dGPU present: %s   driver: %s\n' "$(gpu_present)" "$(gpu_driver)"
		return
	fi

	say "restoring the GPU"
	# The error is NOT suppressed -- no 2>/dev/null, and no 2>&1 either. A
	# failing write here is the single most important thing this test can
	# report, because it means the firmware route back is unavailable and
	# recovery needs the PCI rescan below.
	#
	# This line used to end `2>&1`, which was worse than suppressing it: `>`
	# points stdout at the sysfs node, and `2>&1` then points stderr at the
	# SAME node, so bash's "write error" message was being written INTO
	# gpu_boost. Harmless in practice -- the node parses with kstrtouint and
	# rejects a message beginning with "bash" -- but it defeated the intent
	# stated right here, and a message that happened to start with a digit
	# would have landed a value. Bare stderr goes to the terminal, which is
	# what this comment always claimed.
	if ! echo 4 > "$P/gpu_boost"; then
		echo "  gpu_boost 4 FAILED -- the firmware restore did not run."
		echo "  Check dmesg for an ACPI error naming PEGP._ON."
		RESTORE_OK=0
	fi
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

		RESTORE INCOMPLETE -- the card is on the bus but the driver is not.
		  before: $DRIVER_AT_START
		  after:  $driver

		That is the real answer to this test: the graphics driver does not
		re-bind on its own, and the firmware restore cannot make it.

		REBOOT. Measured on a GAMING A16 5TH, every in-session recovery
		fails, so do not spend time on them:

		  gpu_boost 4         AE_NOT_FOUND on PEGP._ON, aborts WMBD
		  pci/rescan          no-op, the device never left the bus
		  drivers/$DRIVER_AT_START/bind  HANGS the writer in D state, unkillable
		  modprobe -r         refused, the module refcount stays non-zero

		DO NOT write to the driver's bind file. It blocks in the probe and
		cannot be interrupted -- not by Ctrl-C, not by SIGKILL -- and after
		that any further bind or unbind queues behind it and hangs too. It
		makes the reboot harder, not easier.

		  sudo systemctl reboot        # and if that stalls for a few minutes:
		  sudo reboot -f

		Record it -- a detach that costs a reboot every time is a very
		different feature from one that round-trips.
		EOF
		RESTORE_OK=0
	elif [ "$RESTORE_OK" -eq 1 ]; then
		echo "  driver re-bound cleanly -- the round trip works"
	else
		echo "  the card is back and bound, but the firmware restore errored"
		echo "  -- the PCI rescan is what recovered it, not gpu_boost 4."
	fi
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

say "preconditions"
PANEL=$(grep -l '^connected$' /sys/class/drm/card*-eDP-*/status 2>/dev/null | head -1 || true)
# Read the driver behind the connected panel rather than printing advice about
# it. This is the MUX state, and it is the firmware's own interlock: the whole
# of WMBD Case (0x51) sits inside If (DPMF != 0x02), so with the panel on the
# discrete GPU the eject branch is skipped entirely and the write lands
# nowhere. An earlier version named the condition and then detached anyway --
# the exact "advise rather than refuse" pattern the process check below was
# rewritten to avoid.
#
# Match on the driver NAME, never the card index: the indices renumber across a
# MUX switch, so card0/card1 are not stable identities.
PANEL_DRIVER=
if [ -n "$PANEL" ]; then
	PANEL_CARD=${PANEL%/*}                      # .../card1-eDP-1
	PANEL_CARD=/sys/class/drm/$(basename "${PANEL_CARD}" | cut -d- -f1)
	# Test the link exists before resolving it. `readlink -f` canonicalises a
	# path whose final component is missing and prints it anyway, so a card
	# with nothing bound yielded the literal string "driver" rather than an
	# empty result -- which is neither amdgpu nor nvidia, so it slipped past
	# the refusal below into the warn-and-proceed branch. Same shape as the
	# gpu_driver() helper above, which already got this right.
	if [ -e "$PANEL_CARD/device/driver" ]; then
		PANEL_DRIVER=$(basename "$(readlink -f "$PANEL_CARD/device/driver")")
	fi
fi
echo "connected panel:  ${PANEL:-none found}"
echo "  driver behind it: ${PANEL_DRIVER:-unknown}"
echo "dGPU present:     $(gpu_driver | sed "s|^|$(gpu_present), driver |")"

if [ "${GIGABYTE_DETACH_FORCE:-0}" = 1 ]; then
	echo "  GIGABYTE_DETACH_FORCE=1 -- skipping the panel/MUX check"
elif [ -z "$PANEL_DRIVER" ]; then
	die "
Could not read which driver owns the connected internal panel, so whether the
display MUX would block the eject cannot be determined. Refusing to detach
blind. Set GIGABYTE_DETACH_FORCE=1 to override."
elif [ "$PANEL_DRIVER" = nvidia ]; then
	die "
The internal panel is driven by the DISCRETE GPU (driver $PANEL_DRIVER), so
DPMF == 2 and the firmware will skip the whole of Case (0x51). The eject would
not happen, and this test would then report a restore result for a detach that
never occurred.

Switch the MUX back first: BIOS setup -> Peripherals -> \"Switchable Graphics
device\" -> MSHybrid, then reboot and run this again.

Set GIGABYTE_DETACH_FORCE=1 to override."
elif [ "$PANEL_DRIVER" != amdgpu ]; then
	echo "  WARNING: expected amdgpu behind the panel, found $PANEL_DRIVER." >&2
	echo "           Proceeding, but the MUX state is not what this test assumes." >&2
fi

# Refuse rather than advise. The earlier version printed "should be stopped
# first" and then detached anyway, which is the whole hazard this test is
# careful about everywhere else. A process holding the card loses it mid-use,
# and for a compositor that means the session.
#
# The plain Processes table is used, not --query-compute-apps: that query lists
# compute contexts only, so a process using the GPU purely for graphics is
# invisible to it. Measured here, the compositor shows as type C+G -- that
# compute context is the only reason the compute-only query caught it.
# The override has to be honoured on the paths that mention it, not only on the
# one where a process was found. An earlier version told the caller that
# GIGABYTE_DETACH_FORCE=1 would override and then ignored it here, promising
# something the code did not do.
FORCED=0
[ "${GIGABYTE_DETACH_FORCE:-0}" = 1 ] && FORCED=1

echo "processes holding it:"
if ! command -v nvidia-smi >/dev/null; then
	[ "$FORCED" -eq 1 ] || die "
nvidia-smi is not available, so whether anything is using the GPU cannot be
checked. Refusing to detach blind. Set GIGABYTE_DETACH_FORCE=1 to override."
	echo "  nvidia-smi absent -- GIGABYTE_DETACH_FORCE=1, SKIPPING the process check"
	PROCS="No running processes found"
elif ! PROCS=$(nvidia-smi 2>/dev/null | sed -n '/Processes/,$p' | tail -n +4); then
	[ "$FORCED" -eq 1 ] || die "
nvidia-smi failed, so the process check could not run. Refusing to detach
blind. Set GIGABYTE_DETACH_FORCE=1 to override."
	echo "  nvidia-smi failed -- GIGABYTE_DETACH_FORCE=1, SKIPPING the process check"
	PROCS="No running processes found"
else
	echo "$PROCS" | sed 's/^/  /'
fi

# Name the systemd unit behind each holding PID rather than guessing at the
# display manager. On a Fedora/KDE Wayland session the compositor is a systemd
# USER service under user@1000.service, so stopping display-manager takes down
# the login greeter and leaves the running session untouched. Measured on this
# machine: display-manager went inactive, the session went to "closing", and
# kwin_wayland kept the card at the same PID throughout. A PID's cgroup line
# names its unit exactly and costs nothing to read, so there is no reason to
# guess.
#
# SUDO_USER is what makes the user-manager lookup work: this script runs as
# root, and `systemctl --user` as root talks to root's own manager, which does
# not own the desktop.
holder_units() {
	local pid unit seen="" owner="${SUDO_USER:-}" uid
	[ -n "$owner" ] && uid=$(id -u "$owner" 2>/dev/null)

	for pid in $(printf '%s\n' "$PROCS" |
			awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $i > 300) { print $i; break } }'); do
		[ -r "/proc/$pid/cgroup" ] || continue
		# The cgroup v2 line is 0::/path/to/unit, so the unit is the last
		# component. Parameter expansion rather than sed: the unit name and
		# the alternation both want characters that collide with sed's
		# delimiters, and this has nothing to escape.
		unit=$(cat "/proc/$pid/cgroup" 2>/dev/null)
		unit=${unit##*/}
		case "$unit" in *.service|*.scope) ;; *) continue ;; esac
		case " $seen " in *" $unit "*) continue ;; esac
		seen="$seen $unit"

		# A unit that is PartOf graphical-session.target comes down with the
		# target, and stopping the target is what actually ends the session.
		if [ -n "$uid" ] && [ "$(runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
				systemctl --user show "$unit" -p PartOf --value 2>/dev/null)" \
				= graphical-session.target ]; then
			printf '    systemctl --user stop graphical-session.target   # owns %s\n' "$unit"
		else
			printf '    systemctl --user stop %s\n' "$unit"
		fi
	done
}

if ! printf '%s' "$PROCS" | grep -q 'No running processes found'; then
	ADVICE=$(holder_units)
	[ -n "$ADVICE" ] || ADVICE="    (could not identify the owning unit -- log out of the desktop)"

	[ "$FORCED" -eq 1 ] || die "
Something is still using the discrete GPU, listed above. Detaching now takes
the card away from it -- for a compositor that means your session.

Stop it first. These are the systemd units behind the processes listed above,
read from each PID's own cgroup:

$ADVICE

Run those WITHOUT sudo -- they are user units, and as root you would be
talking to root's manager instead of yours.

NOT 'systemctl stop display-manager'. On a systemd user session that stops the
login greeter only: the session's own units live under user@1000.service and
keep the card. Verified on a GAMING A16 5TH, where it left kwin_wayland
running at an unchanged PID.

Afterwards, to get the desktop back:
    sudo systemctl start display-manager

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
# DETACHED gates the restore. Set it BEFORE the write, not after: if the eject
# lands and the script is then interrupted, the card is already gone and the
# restore must still run. A flag set afterwards would miss exactly that case.
DETACHED=1
# Clear the flag again if the write itself failed. The flag is deliberately set
# BEFORE the write so an interrupt between a landed eject and the next line
# still restores -- but a write that FAILED ejected nothing, and leaving the
# flag set made restore() send gpu_boost 4 to a still-attached card. That is an
# ACPI BIOS Error in the log plus a restore narrative for a detach that never
# happened. Both orderings are needed, so set it early and unset it on failure.
echo 3 > "$P/gpu_boost" || { DETACHED=0; die "write to gpu_boost failed -- nothing was ejected"; }
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
	# Present afterwards means one of two things, and they are not the same.
	# An earlier version printed only the second and blamed the firmware, which
	# was wrong on this machine: the panel was on amdgpu so the interlock was
	# satisfied, the notify WAS serviced -- nvidia-drm removed the device and
	# unloaded -- and the card still stayed on the bus.
	echo
	echo "The card is still on the bus."
	if [ "$(gpu_driver)" != "$DRIVER_AT_START" ]; then
		cat <<-EOF
		But the driver is gone: was $DRIVER_AT_START, now $(gpu_driver).

		So the eject WAS serviced and only half-completed -- the graphics
		driver unbound, the PCI device did not leave. Look for
		"Attempting to remove device ... with non-zero usage count" in the
		log above: something held a reference and the removal stopped after
		the unbind.

		This is not a firmware refusal. It is also not recoverable in this
		session -- see the restore block below. Do NOT write to the driver's
		bind file: it hangs uninterruptibly and makes the reboot worse.
		EOF
	else
		cat <<-EOF
		And the driver is still bound, so nothing happened at all.
		Most likely the firmware refused it: check the panel line above --
		a detach is refused while the panel is on the discrete GPU.
		EOF
		# Nothing was ejected, so there is nothing to restore. Clearing the
		# flag is what stops restore() sending gpu_boost 4 to a card that is
		# still attached and bound -- a write measured to abort WMBD on an
		# unresolved PEGP._ON and put an ACPI BIOS Error in the kernel log.
		#
		# The earlier fix covered the write FAILING. This is the other half:
		# the write succeeded and had no effect, which the firmware's own
		# DPMF gate does silently. Both need the flag down, and only one had
		# been thought through.
		DETACHED=0
	fi
fi

restore
