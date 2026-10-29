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
# exit path, including Ctrl-C.
#
# IT IS SLOW, around 8 minutes, and that is deliberate. Every reading samples
# the limit for LIMIT_SAMPLES seconds and takes the minimum, because the
# enforced limit wanders on its own and a single read lands wherever
# arbitration happens to be. A faster window would reintroduce the false
# failures this is here to prevent.

set -uo pipefail   # deliberately not -e: a failure must still reach the restore

P=/sys/devices/platform/gigabyte_laptop
PROFILE=/sys/firmware/acpi/platform_profile
SETTLE=6           # the enforced limit takes several seconds to update;
                   # reading sooner reports the PREVIOUS value
LIMIT_SAMPLES=30   # seconds of sampling per reading, minimum taken -- see
                   # limit(). It MUST outlast an arbitration excursion or the
                   # minimum is the excursion rather than the floor, which is
                   # the false failure this sampling exists to prevent. The
                   # longest excursion measured was about 20 s, so 30 carries
                   # a 50% margin. This was 12 when first written, which is
                   # shorter than the excursion the comment beside it already
                   # named -- the value and its own justification disagreed.

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
RESTORE_OK=1
# Report a restore that did not land. These four writes used to discard both
# stderr and their exit status, so a failed one left the setting changed while
# "== restored ==" printed and the script exited on the test result alone. This
# test moves fan policy and a power tier, so a silent half-restore is the one
# failure that matters more than the verdict -- it leaves the machine audible,
# or pinned, with nothing saying why.
put_back() {   # put_back <value> <path> <label>
	if ! echo "$1" > "$2" 2>/dev/null; then
		echo "  RESTORE FAILED: $3 could not be set back to '$1'" >&2
		RESTORE_OK=0
	fi
}
restore() {
	[ "$restored" -eq 1 ] && return
	restored=1
	put_back "$BOOST_WAS"      "$P/gpu_boost"    gpu_boost
	put_back "$PRESET_WAS"     "$P/power_preset" power_preset
	put_back "$FAN_PRESET_WAS" "$P/fan_preset"   fan_preset
	put_back "$PROFILE_WAS"    "$PROFILE"        platform_profile
	sleep "$SETTLE"

	# Write fan_mode back ONLY for a custom mode (3+), and never for 0-2.
	#
	# fan_mode_store() pins fan_preset from the mode it is given:
	# fan_mode_presets[] covers 0-2 (normal/silent/gaming), and anything above
	# that falls back to FAN_PRESET_AUTO. So the two states cannot both be
	# written blindly, and the ordering decides which one survives:
	#
	#   saved preset  saved mode   what restores both
	#   ------------  ----------   -------------------------------------------
	#   pinned        0-2          the preset write above; it sets the mode
	#   auto          0-2          the preset write above ONLY -- writing the
	#                              mode would pin the preset and hand fan
	#                              policy back to nobody
	#   auto          3+ custom    the mode write; mode 3+ sets preset = auto
	#                              itself, so both land
	#
	# An earlier version wrote the mode whenever it differed, which undid the
	# preset restore two lines above and exited with the preset pinned. The
	# preset is the POLICY -- who owns the fans -- and a mode derived under
	# `auto` is the profile's to re-pick, so the preset is the one to protect.
	if [ "$FAN_MODE_AT_START" -ge 3 ] 2>/dev/null &&
	   [ "$(cat "$P/fan_mode" 2>/dev/null)" != "$FAN_MODE_AT_START" ]; then
		put_back "$FAN_MODE_AT_START" "$P/fan_mode" fan_mode
		sleep 1
	fi
	if [ "$RESTORE_OK" -eq 1 ]; then
		printf '\n== restored ==\n'
	else
		printf '\n== RESTORE INCOMPLETE -- check the values below by hand ==\n' >&2
	fi
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
# Check this write. The preceding loop leaves perf_mode at 2, which is already
# 70 W, so a write that failed here would leave the limit at the expected value
# and the row would print ok for a preset that was never applied.
echo boost > "$P/power_preset" || die "write to power_preset failed"
check "power_preset boost" "70.00"
echo "low-power" > "$PROFILE" || die "write to $PROFILE failed"
check "low-power while pinned to boost" "70.00"

# Assert the readback rather than printing it. The limit checks above cannot
# see a getter that reports 'auto' while the tier is still applied, so without
# this the pinning contract is only half tested.
got_preset=$(cat "$P/power_preset")
if [ "$got_preset" = boost ]; then
	printf '  %-34s %-10s ok\n' "power_preset reads back pinned" "$got_preset"
	pass=$((pass + 1))
else
	printf '  %-34s %-10s EXPECTED boost\n' "power_preset reads back pinned" "$got_preset"
	fail=$((fail + 1))
fi

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
if [ "$skip" -gt 0 ]; then printf ', %d skipped' "$skip"; fi
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
if [ "$RESTORE_OK" -ne 1 ]; then
	echo "  The machine was NOT fully restored -- see RESTORE FAILED above." >&2
	exit 1
fi
exit $((fail > 0))
