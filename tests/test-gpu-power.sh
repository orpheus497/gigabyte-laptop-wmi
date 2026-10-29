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

die() { echo "$*" >&2; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$P" ] || die "driver not loaded: $P does not exist"
[ -e "$P/perf_mode" ] || die "perf_mode is absent: not Gigabyte Gaming firmware"
command -v nvidia-smi >/dev/null || die "needs nvidia-smi to read the power limit"
[ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)" = 1 ] || \
	die "not on AC -- the GPU power path is firmware-blocked on battery"

limit() { nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader; }

PRESET_WAS=$(cat "$P/power_preset")
BOOST_WAS=$(cat "$P/gpu_boost")
PROFILE_WAS=$(cat "$PROFILE")

restored=0
restore() {
	[ "$restored" -eq 1 ] && return
	restored=1
	echo "$BOOST_WAS"   > "$P/gpu_boost"    2>/dev/null
	echo "$PRESET_WAS"  > "$P/power_preset" 2>/dev/null
	echo "$PROFILE_WAS" > "$PROFILE"        2>/dev/null
	sleep "$SETTLE"
	printf '\n== restored ==\n'
	printf '  profile=%s power_preset=%s perf_mode=%s gpu_boost=%s fan_mode=%s\n' \
		"$(cat "$PROFILE")" "$(cat "$P/power_preset")" \
		"$(cat "$P/perf_mode")" "$(cat "$P/gpu_boost")" "$(cat "$P/fan_mode")"
	printf '  GPU limit=%s\n' "$(limit)"
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

# check <label> <expected> -- compares against the live limit after settling
pass=0; fail=0
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
for pair in "0 50.00" "1 60.00" "2 70.00"; do
	set -- $pair
	echo "$1" > "$P/perf_mode"
	check "perf_mode $1" "$2"
done

say "gpu_boost is a second axis under the tier"
echo 2 > "$P/perf_mode"; sleep "$SETTLE"
echo 0 > "$P/gpu_boost";  check "gpu_boost 0 at tier 2" "50.00"
echo 1 > "$P/gpu_boost";  check "gpu_boost 1 at tier 2" "70.00"

say "power_preset pins a tier against the profile"
echo boost > "$P/power_preset"; check "power_preset boost" "70.00"
echo "low-power" > "$PROFILE"
check "low-power while pinned to boost" "70.00"
printf '  %-34s %s\n' "(preset still reads)" "$(cat "$P/power_preset")"

say "auto re-tethers to the profile"
echo auto > "$P/power_preset"; check "auto, profile is low-power" "50.00"

say "the profile mapping drives both axes"
for pair in "low-power 50.00 1" "balanced 60.00 1" "performance 70.00 0"; do
	set -- $pair
	echo "$1" > "$PROFILE"
	check "profile $1" "$2"
	got_fan=$(cat "$P/fan_mode")
	if [ "$got_fan" = "$3" ]; then
		printf '  %-34s fan_mode=%s ok\n' "" "$got_fan"
	else
		printf '  %-34s fan_mode=%s EXPECTED %s\n' "" "$got_fan" "$3"
		fail=$((fail + 1))
	fi
done

say "result"
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "  The GPU power contract holds." \
	|| echo "  Something has changed -- check CLAUDE.md's ACBT decode against the firmware."

restore
exit $((fail > 0))
