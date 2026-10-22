#!/bin/bash
# Does the embedded controller honour the charge ceiling?
#
# The question cannot be answered by reading anything back. BCPC lives in a
# SystemMemory window, so WMBD's post-write read is a read-after-write of the
# byte we just wrote: it proves the ACPI store landed and nothing about whether
# the EC consumed it. Only the battery's own behaviour settles it, which means
# watching it charge up to the ceiling and seeing whether it stops.
#
# So this has to wait, and that is why it is a script rather than a sequence of
# commands to time by hand.
#
# Usage: sudo bash scripts/test-charge-limit.sh [ceiling]
#
# Restores the original values on every exit path, including Ctrl-C.

set -uo pipefail   # deliberately not -e: a failure must still reach the restore

CEILING=${1:-80}
P=/sys/devices/platform/gigabyte_laptop
POLL=30            # seconds between samples
TIMEOUT=$((60*60)) # give up after an hour

die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (the charge nodes and debug_method are 0600)"
[ -d "$P" ] || die "driver not loaded: $P does not exist"

BAT=$(echo /sys/class/power_supply/BAT* | awk '{print $1}')
[ -r "$BAT/capacity" ] || die "no battery found under /sys/class/power_supply"

ac_online() {
	local f
	for f in /sys/class/power_supply/*/online; do
		[ -r "$f" ] && [ "$(cat "$f")" = "1" ] && return 0
	done
	return 1
}

# Raw field read, so the cached sysfs nodes cannot mislead us. 0x5A is a
# sentinel: if it comes back, the method is not implemented.
raw() {
	echo "$1 0x5A" > "$P/debug_method" || return 1
	cat "$P/debug_method"
}

(( CEILING >= 60 && CEILING <= 100 )) || die "ceiling must be 60..100 (the driver's own range)"

echo "== Preconditions =="
CAP=$(cat "$BAT/capacity")
ST=$(cat "$BAT/status")
echo "   battery  : ${CAP}% ${ST}"
echo "   AC       : $(ac_online && echo online || echo OFFLINE)"

ac_online || die "
Plug the charger in. The ceiling can only be observed from below, by watching
the battery climb to it, so this needs AC."

if (( CAP >= CEILING - 2 )); then
	die "
Battery is at ${CAP}% and the ceiling is ${CEILING}%. Starting at or above the
ceiling proves nothing -- that is exactly what made the first attempt at this
test inconclusive. Run the battery down to roughly $((CEILING - 20))%, or pass a
higher ceiling as an argument."
fi

echo
echo "== Baseline (record these; no firmware path restores them) =="
BASE_MODE=$(raw 0x64) || die "could not read 0x64"
BASE_LIMIT=$(raw 0x65) || die "could not read 0x65"
echo "   0x64 BCPS : $BASE_MODE"
echo "   0x65 BCPC : $BASE_LIMIT"

restore() {
	echo
	echo "== Restoring =="
	# Mode off first, then the limit: disabling the mode stops the ceiling
	# being enforced before we widen it.
	echo 0   > "$P/charge_mode"  2>/dev/null
	echo 100 > "$P/charge_limit" 2>/dev/null
	echo "   0x64 BCPS : $(raw 0x64)"
	echo "   0x65 BCPC : $(raw 0x65)"
	echo "   (compare against the baseline above)"
}
trap restore EXIT

echo
echo "== Applying: limit ${CEILING}, then mode on =="
# Limit before mode. Enabling the mode latches whatever BCPC already holds, and
# nothing in the driver enforces the order.
echo "$CEILING" > "$P/charge_limit" || die "write to charge_limit failed"
echo 1          > "$P/charge_mode"  || die "write to charge_mode failed"
echo "   0x65 BCPC : $(raw 0x65)   <- store landed; says nothing about the EC"
echo "   0x64 BCPS : $(raw 0x64)"

echo
echo "== Watching. Ctrl-C is safe: the restore runs anyway. =="
START=$SECONDS
VERDICT="INCONCLUSIVE"

while (( SECONDS - START < TIMEOUT )); do
	CAP=$(cat "$BAT/capacity")
	ST=$(cat "$BAT/status")
	printf '   %4ds  %3s%%  %s\n' "$((SECONDS - START))" "$CAP" "$ST"

	if ! ac_online; then
		VERDICT="ABORTED: charger was unplugged"
		break
	fi

	# Stopped at the ceiling: the EC honours BCPC.
	if (( CAP >= CEILING - 1 )) && [ "$ST" != "Charging" ]; then
		VERDICT="HONOURED: charging stopped at ${CAP}% with a ${CEILING}% ceiling"
		break
	fi

	# Sailed past it with room to spare: the EC is ignoring BCPC.
	if (( CAP >= CEILING + 4 )); then
		VERDICT="IGNORED: still ${ST} at ${CAP}% with a ${CEILING}% ceiling"
		break
	fi

	sleep "$POLL"
done

echo
echo "== Verdict =="
echo "   $VERDICT"
