#!/bin/bash
# Do the APU's two short-burst power limits bind?
#
# The sustained limit is settled: a yes(1) load drew ~62 W in perf_mode 0,
# which writes a 45 W sustained limit, so that limit is not enforced. What that
# load never reached was the 65 W burst figures, so the burst limits are
# untested rather than disproven.
#
# Usage: sudo bash tests/test-apu-burst.sh
#
# Lowest-value item on the open list: burst limits govern brief excursions and
# the sustained limit is what matters for real behaviour.
# This needs a HEAVIER load than yes(1), which is integer-only. stress-ng's
# vector and matrix methods push the FPU and draw more; openssl's AES path is
# the fallback. The question is whether package power can be pushed past 65 W
# at all, and if so whether the clock drops when it gets there.
#
# Needs mains. Cooling is pinned to gaming so the fans are not a variable, and
# BOTH the preset and the profile are restored on every exit path -- including
# Ctrl-C, which the earlier hand-written sweeps got wrong twice.
#
# RUNS FOR 90 SECONDS. perf_mode steps at 30 s and 60 s.

S=/sys/devices/platform/gigabyte_laptop
E=/sys/class/powercap/intel-rapl:0/energy_uj
# hwmon numbering is not stable across reboots, so find it by name
K=$(dirname "$(grep -l '^k10temp$' /sys/class/hwmon/*/name 2>/dev/null)" 2>/dev/null)

[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
[ "$(cat /sys/class/power_supply/ACAD/online)" = 1 ] || {
	echo "Not on AC. The firmware writes different limits on battery."
	exit 1
}
[ -r "$E" ] || { echo "Cannot read $E"; exit 1; }

if command -v stress-ng >/dev/null; then
	LOAD=(stress-ng --cpu 0 --cpu-method matrixprod --metrics-brief -t 95s)
	echo "load: stress-ng matrixprod on all cores"
else
	echo "stress-ng not installed -- install it for a heavier load:"
	echo "    sudo dnf install stress-ng"
	echo "falling back to openssl AES, which is lighter but still beats yes(1)"
	LOAD=(sh -c 'for i in $(seq '"$(nproc)"'); do openssl speed -evp aes-256-gcm >/dev/null 2>&1 & done; wait')
fi

PRESET_WAS=$(cat $S/fan_preset)
PROFILE_WAS=$(cat /sys/firmware/acpi/platform_profile)
pids=""
done_once=0

cleanup() {
	[ "$done_once" = 1 ] && return
	done_once=1
	[ -n "$pids" ] && kill $pids 2>/dev/null
	pkill -f stress-ng 2>/dev/null
	pkill -f 'openssl speed' 2>/dev/null
	echo "$PROFILE_WAS" > /sys/firmware/acpi/platform_profile 2>/dev/null
	echo "$PRESET_WAS"  > $S/fan_preset
	printf '\n== restored: fan_preset=%s platform_profile=%s ==\n' \
		"$PRESET_WAS" "$PROFILE_WAS"
	printf '   perf_mode=%s power_preset=%s fan_mode=%s\n' \
		"$(cat $S/perf_mode)" "$(cat $S/power_preset)" "$(cat $S/fan_mode)"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

echo gaming > $S/fan_preset
echo 0      > $S/perf_mode
sleep 3

"${LOAD[@]}" >/dev/null 2>&1 & pids="$pids $!"
echo
echo "RUNS FOR 90 SECONDS. perf_mode steps at 30 s and 60 s. Ctrl-C restores."
echo
printf '%4s %5s %6s %7s %5s\n' sec mode pkgW clkMHz k10C

prev=$(cat "$E")
for t in $(seq 1 90); do
	sleep 1
	now=$(cat "$E")
	printf '%4d %5s %6d %7d %5d\n' \
		"$t" "$(cat $S/perf_mode)" \
		"$(( (now - prev) / 1000000 ))" \
		"$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))" \
		"$(( $(cat "$K/temp1_input" 2>/dev/null || echo 0) / 1000 ))"
	prev=$now
	case $t in
	30) echo 1 > $S/perf_mode ;;
	60) echo 2 > $S/perf_mode ;;
	esac
done

cat <<'EOF'

How to read it:

  pkgW never exceeds ~65 W
      The load still is not heavy enough. The burst limits remain untested,
      and that is the end of what can be learned without a heavier load.

  pkgW exceeds 65 W and clkMHz is flat across all three modes
      The burst limits are not enforced either. The APU half of perf_mode does
      nothing at all, and row 7 closes completely.

  pkgW exceeds 65 W and clkMHz DROPS in mode 0 but not in mode 2
      The burst limits ARE enforced. perf_mode does control APU power under
      short excursions, and the sustained-limit result stands alongside it
      rather than replacing it. That would be a real finding.
EOF
