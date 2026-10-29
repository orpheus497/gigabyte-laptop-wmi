#!/bin/bash
# Regression test for the GPU power controls: the perf_mode tiers, gpu_boost as
# a second axis, and the platform_profile mapping that drives both.
#
# This is the contract a userland GUI is written against, so it is worth being
# able to re-run after a BIOS update or a kernel change rather than
# rediscovering it. Every expected value below was measured on a GAMING A16 5TH
# (BIOS FB03) and follows from the firmware's own constants:
#
#   enforced.power.limit = 50 W + NPCF.ACBT / 8
#
#   perf_mode 0 -> ACBT 0x00 ->  50 W      gpu_boost 0 -> ACBT 0    -> 50 W
#   perf_mode 1 -> ACBT 0x50 ->  60 W      gpu_boost 1 -> ACBT LCBT -> tier
#   perf_mode 2 -> ACBT 0xA0 ->  70 W
#
# Needs mains: on battery the firmware withholds the DC power-limit table from
# nvidia-powerd, so none of these writes has a consumer and every reading stays
# put. That is not a failure, it is the documented behaviour.
#
# Usage: sudo bash tests/test-gpu-power.sh
#
# Restores perf_mode, gpu_boost, power_preset and the platform profile on every
# exit path, including Ctrl-C. Takes about a minute.

set -uo pipefail   # deliberately not -e: a failure must still reach the restore

P=/sys/devices/platform/gigabyte_laptop
PROFILE=/sys/firmware/acpi/platform_profile
SETTLE=6           # the enforced limit takes several seconds to update;
                   # reading sooner reports the PREVIOUS value
LIMIT_SAMPLES=12   # seconds of sampling per reading, minimum taken -- see
                   # limit(). Must outlast an arbitration excursion, which was
                   # measured at around twenty seconds, so this is deliberately
                   # long rather than a token average.

die() { echo "$*" >&2; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$P" ] || die "driver not loaded: $P does not exist"
[ -e "$P/perf_mode" ] || die "perf_mode is absent: not Gigabyte Gaming firmware"
command -v nvidia-smi >/dev/null || die "needs nvidia-smi to read the power limit"
[ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)" = 1 ] || \
	die "not on AC -- the GPU power path is firmware-blocked on battery"

limit_now() { nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader; }

# enforced.power.limit is the ARBITRATED limit, not a static setting. Measured
# 29 Oct 2026 with amd_pmf bound and nothing being written: it sat at 60 W,
# rose to 75 W unprompted for twenty seconds, and fell back to 60 W. A single
# sample therefore reports wherever Dynamic Boost happens to be at that
# instant, which is how three checks "failed" in a run whose later checks
# passed on the very same tiers.
#
# The minimum over a window is the right statistic: arbitration raises the
# limit above the tier's base and never below it, so the floor is the tier.
limit() {
	local i v lo=""
	for i in $(seq "$LIMIT_SAMPLES"); do
		v=$(limit_now); v=${v%% *}
		[ -z "$lo" ] && lo=$v
		awk -v a="$v" -v b="$lo" 'BEGIN{exit !(a<b)}' && lo=$v
		sleep 1
	done
	printf '%s W' "$lo"
}


# gpu_boost is gated by the display MUX, and perf_mode is not. WMBD Case (0x51)
# sits inside If (DPMF != 0x02), so with the panel routed to the discrete GPU
# the firmware skips the whole routine and every gpu_boost write is silently
# inert -- measured 29 Oct 2026, floor unchanged at the tier where a landed
# write gives 50 W. Case (0xED) has no such gate, only an ACST branch, so the
# tiers keep working.
#
# Detect it rather than failing three checks for a reason that is not a defect.
# The connected eDP names the card driving the panel, which is what the MUX
# selects, and it needs no root and no WMI call.
MUX=hybrid
for s in /sys/class/drm/card*-eDP-*/status; do
	[ -e "$s" ] || continue
	[ "$(cat "$s")" = connected ] || continue
	card=$(basename "$(dirname "$s")")
	drv=$(basename "$(readlink -f "/sys/class/drm/${card%%-*}/device/driver" 2>/dev/null)" 2>/dev/null)
	[ "$drv" = nvidia ] && MUX=discrete
done

if [ "$MUX" = discrete ]; then
	cat <<-'EOF'

	NOTE: the panel is on the discrete GPU, so the display MUX is in discrete
	mode and gpu_boost is INERT -- the firmware gates WMBD Case (0x51) behind
	If (DPMF != 0x02). Its two checks are skipped, and they are reported as
	skipped rather than passed, because nothing about them was verified.

	perf_mode is unaffected and its three tiers are tested as usual. To test
	gpu_boost, put the MUX back: BIOS setup, Peripherals -> Switchable
	Graphics device -> MSHybrid.
	EOF
fi
PROFILE_WAS=$(cat "$PROFILE")

# The aggregate is the intersection of every registered handler's choices and
# reads "custom" when they disagree. Writing it then cannot restore the
# per-handler state this script found, so refuse rather than leave the machine
# somewhere it did not start. Reachable once amd_pmf binds and registers a
# second handler.
if [ "$PROFILE_WAS" = custom ]; then
	echo "Registered platform_profile handlers:" >&2
	for n in /sys/class/platform-profile/*/name; do
		[ -e "$n" ] && printf '  %-20s profile=%s\n' \
			"$(cat "$n")" "$(cat "$(dirname "$n")/profile")" >&2
	done
	die "
the aggregate profile reads 'custom', meaning two or more handlers disagree.
Restoring it afterwards would be impossible, so this refuses to start. Set the
handlers to agree first, or unbind the second one."
fi

PRESET_WAS=$(cat "$P/power_preset")
BOOST_WAS=$(cat "$P/gpu_boost")
FAN_PRESET_WAS=$(cat "$P/fan_preset")
FAN_MODE_AT_START=$(cat "$P/fan_mode")

# A profile only moves the fans while the fan preset is auto AND the fan mode is
# one of the three embedded-controller presets. Anything else is a deliberate
# hold the driver will not override -- correct behaviour, but it would make the
# mapping checks below fail for a reason that is not a defect. Say so up front
# rather than reporting a false failure.
if [ "$FAN_MODE_AT_START" -gt 2 ] 2>/dev/null; then
	die "
fan_mode is $FAN_MODE_AT_START -- a custom curve, a held duty or full speed. A
profile switch deliberately leaves the fans alone in that state, so the mapping
checks cannot run. Put the fans back on an embedded-controller preset first:
    echo 1 > $P/fan_mode"
fi

restored=0
restore() {
	[ "$restored" -eq 1 ] && return
	restored=1
	echo "$BOOST_WAS"       > "$P/gpu_boost"    2>/dev/null
	echo "$PRESET_WAS"      > "$P/power_preset" 2>/dev/null
	echo "$FAN_PRESET_WAS"  > "$P/fan_preset"   2>/dev/null
	echo "$PROFILE_WAS"     > "$PROFILE"        2>/dev/null
	sleep "$SETTLE"

	# Restoring the preset and the profile usually restores the mode with them,
	# because with the preset on auto the profile decides the mode and with it
	# pinned the preset decides. One case escapes that: a freshly loaded driver
	# has the preset on auto and the mode read from the firmware, which need
	# not be the mode the profile maps to. Writing it back explicitly covers
	# that, and is a no-op whenever the two already agree.
	if [ "$(cat "$P/fan_mode")" != "$FAN_MODE_AT_START" ]; then
		echo "$FAN_MODE_AT_START" > "$P/fan_mode" 2>/dev/null
		sleep 1
	fi
	printf '\n== restored ==\n'
	printf '  profile=%s power_preset=%s fan_preset=%s\n' \
		"$(cat "$PROFILE")" "$(cat "$P/power_preset")" "$(cat "$P/fan_preset")"
	printf '  perf_mode=%s gpu_boost=%s fan_mode=%s\n' \
		"$(cat "$P/perf_mode")" "$(cat "$P/gpu_boost")" "$(cat "$P/fan_mode")"
	printf '  GPU limit=%s\n' "$(limit)"
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

# check <label> <expected> -- compares against the live limit after settling
pass=0; fail=0; skip=0
check() {
	sleep "$SETTLE"
	local got; got=$(limit)
	if [ "${got%% *}" = "$2" ]; then
		printf '  %-34s %-10s ok\n' "$1" "$got"; pass=$((pass + 1))
	else
		printf '  %-34s %-10s EXPECTED %s W\n' "$1" "$got" "$2"; fail=$((fail + 1))
	fi
}

say "the three perf_mode tiers"
echo "auto" > "$P/power_preset"      # make sure nothing is pinned
# gpu_boost gates the same NPCF.ACBT field the tiers set: with it at 0, ACBT is
# zero and EVERY tier reads 50 W. Starting a run with boost already off would
# therefore fail all three checks for a reason that is not a tier defect. It is
# put back from BOOST_WAS by the restore.
echo 1 > "$P/gpu_boost"
for pair in "0 50.00" "1 60.00" "2 70.00"; do
	set -- $pair
	echo "$1" > "$P/perf_mode"
	check "perf_mode $1" "$2"
done

say "gpu_boost is a second axis under the tier"
if [ "$MUX" = discrete ]; then
	printf '  %-34s %-10s SKIPPED (MUX is discrete)\n' "gpu_boost 0 at tier 2" "-"
	printf '  %-34s %-10s SKIPPED (MUX is discrete)\n' "gpu_boost 1 at tier 2" "-"
	skip=$((skip + 2))
else
	echo 2 > "$P/perf_mode"; sleep "$SETTLE"
	echo 0 > "$P/gpu_boost";  check "gpu_boost 0 at tier 2" "50.00"
	echo 1 > "$P/gpu_boost";  check "gpu_boost 1 at tier 2" "70.00"
fi

say "power_preset pins a tier against the profile"
echo boost > "$P/power_preset"; check "power_preset boost" "70.00"
echo "low-power" > "$PROFILE"
check "low-power while pinned to boost" "70.00"
printf '  %-34s %s\n' "(preset still reads)" "$(cat "$P/power_preset")"

say "auto re-tethers to the profile"
echo auto > "$P/power_preset"; check "auto, profile is low-power" "50.00"

say "the profile mapping drives both axes"
# Both rings must be on auto for a profile to own either axis. The fan one is
# restored from FAN_PRESET_WAS afterwards.
echo auto > "$P/fan_preset"
echo auto > "$P/power_preset"
for pair in "low-power 50.00 1" "balanced 60.00 1" "performance 70.00 0"; do
	set -- $pair
	echo "$1" > "$PROFILE"
	check "profile $1" "$2"
	got_fan=$(cat "$P/fan_mode")
	if [ "$got_fan" = "$3" ]; then
		printf '  %-34s fan_mode=%s ok\n' "" "$got_fan"
		pass=$((pass + 1))
	else
		printf '  %-34s fan_mode=%s EXPECTED %s\n' "" "$got_fan" "$3"
		fail=$((fail + 1))
	fi
done

say "result"
printf '  %d passed, %d failed' "$pass" "$fail"
[ "$skip" -gt 0 ] && printf ', %d skipped' "$skip"
printf '\n'
if [ "$fail" -ne 0 ]; then
	echo "  Something has changed -- check CLAUDE.md's ACBT decode against the firmware."
elif [ "$skip" -gt 0 ]; then
	echo "  Everything tested holds. The skipped checks are not a pass -- the"
	echo "  display MUX has to go back to MSHybrid for gpu_boost to be testable."
else
	echo "  The GPU power contract holds."
fi

restore
exit $((fail > 0))
