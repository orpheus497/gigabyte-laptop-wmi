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
POLL=30             # seconds between samples
TIMEOUT=$((60*60))  # give up after an hour
HELD_UA=150000      # below this the battery is not really being charged
                    # (measured: ~3.4 A while charging on this chassis)
FLAT_NEEDED=4       # samples of unchanged capacity that count as "held"

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

# Refuse a baseline from a method this firmware does not implement. WMBC ends in
# Default { Return (Arg2) }, so an absent ID echoes the 0x5A sentinel, which
# parses as a thoroughly plausible 90 -- enough to run the whole test against a
# field nothing reads, then "restore" 90 as the ceiling.
#
# Match the brackets, not the bare word. The negative form is
#   [not implemented: reply was not an integer]
# which *contains* "implemented", so a *implemented* glob passes both.
for reply in "$BASE_MODE" "$BASE_LIMIT"; do
	case $reply in
	*"[implemented]"*) ;;
	*) die "
This firmware does not implement the charging methods:
  $BASE_MODE
  $BASE_LIMIT
There is no ceiling to test and no baseline to put back." ;;
	esac
done

# The decimal in parentheses, for the restore. Printed form is
#   method 0x65 arg 0x5a -> 0x50 (80) [implemented]
BASE_MODE_N=$(printf '%s' "$BASE_MODE" | sed -n 's/.*(\([0-9]\+\)).*/\1/p')
BASE_LIMIT_N=$(printf '%s' "$BASE_LIMIT" | sed -n 's/.*(\([0-9]\+\)).*/\1/p')
[ -n "$BASE_MODE_N" ] && [ -n "$BASE_LIMIT_N" ] ||
	die "could not parse the baseline values; refusing to run without a restore path"

# Only bit 2 of BCPS is the mode, and charge_mode takes 0 or 1.
BASE_MODE_BIT=$(( (BASE_MODE_N >> 2) & 1 ))

if [ "$BASE_MODE_BIT" = "1" ]; then
	echo
	echo "   NOTE: a ceiling of ${BASE_LIMIT_N}% is already in force. The test will"
	echo "         set ${CEILING}% and put ${BASE_LIMIT_N}% back afterwards."
fi

restore() {
	echo
	echo "== Restoring the recorded baseline =="
	# The limit first and the mode last, mirroring the apply path: enabling
	# the mode latches whatever the ceiling already holds, so the ceiling
	# has to be right before the enable bit goes up. Writing a fixed 0/100
	# here instead would silently discard a ceiling the user already had.
	#
	# charge_limit refuses anything below 60, and BCPC has been observed
	# reading 0 on this hardware -- so a faithful restore of a sub-60
	# baseline cannot go through the node. Fall back to the raw WMBD write,
	# which has no such floor. The mode still goes through its own node
	# afterwards, so the driver's cache stays truthful.
	if ! echo "$BASE_LIMIT_N" > "$P/charge_limit" 2>/dev/null; then
		echo "   charge_limit refused ${BASE_LIMIT_N} (below its 60 floor); restoring BCPC through debug_method_write"
		echo "0x65 $BASE_LIMIT_N" > "$P/debug_method_write" 2>/dev/null ||
			echo "   WARNING: could not restore BCPC to ${BASE_LIMIT_N}" >&2
	fi
	echo "$BASE_MODE_BIT" > "$P/charge_mode" 2>/dev/null
	echo "   0x64 BCPS : $(raw 0x64)"
	echo "   0x65 BCPC : $(raw 0x65)"
	echo "   (expected: BCPS $BASE_MODE_N, BCPC $BASE_LIMIT_N)"
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
LAST_CAP=-1
FLAT=0

while (( SECONDS - START < TIMEOUT )); do
	CAP=$(cat "$BAT/capacity")
	ST=$(cat "$BAT/status")
	CUR=$(cat "$BAT/current_now" 2>/dev/null || echo 0)
	printf '   %4ds  %3s%%  %-12s %5s mA\n' \
		"$((SECONDS - START))" "$CAP" "$ST" "$((CUR/1000))"

	if ! ac_online; then
		VERDICT="ABORTED: charger was unplugged"
		break
	fi

	# Sailed past it with room to spare: the EC is ignoring BCPC.
	if (( CAP >= CEILING + 4 )); then
		VERDICT="IGNORED: still ${ST} at ${CAP}% with a ${CEILING}% ceiling"
		break
	fi

	# Stopped at the ceiling: the EC honours BCPC.
	#
	# Do NOT test status alone. Measured on a GAMING A16 5TH: the EC holds
	# the charge but the battery keeps reporting "Charging", so an earlier
	# version of this check never fired even though the ceiling worked. What
	# actually changes is the current -- about 3.4 A charging, near zero when
	# held -- and the capacity stops rising.
	if (( CAP >= CEILING - 1 )); then
		if [ "$ST" != "Charging" ] || (( CUR < HELD_UA )); then
			VERDICT="HONOURED: held at ${CAP}% with a ${CEILING}% ceiling (status ${ST}, $((CUR/1000)) mA)"
			break
		fi

		# Fallback that assumes nothing about either field: the capacity
		# simply stopped climbing while at the ceiling.
		if (( CAP == LAST_CAP )); then
			(( FLAT++ ))
			if (( FLAT >= FLAT_NEEDED )); then
				VERDICT="HONOURED: capacity flat at ${CAP}% for $((FLAT*POLL))s with a ${CEILING}% ceiling"
				break
			fi
		else
			FLAT=0
		fi
	fi
	LAST_CAP=$CAP


	sleep "$POLL"
done

echo
echo "== Verdict =="
echo "   $VERDICT"
