#!/bin/bash
# Do the APU's two short-burst power limits bind?
#
# The sustained limit is settled: a yes(1) load drew ~62 W in perf_mode 0,
# which writes a 45 W sustained limit, so that limit is not enforced. What that
# load never reached was the 65 W burst figures, so the burst limits are
# untested rather than disproven.
#
# This needs a HEAVIER load than yes(1), which is integer-only. stress-ng's
# matrix method pushes the FPU and draws more; a repeated openssl AES benchmark
# is the fallback. The question is whether package power can be pushed past
# 65 W at all, and if so whether the clock drops when it gets there.
#
# Usage: sudo bash tests/test-apu-burst.sh
#
# Needs mains. Cooling is pinned to gaming so the fans are not a variable, and
# the preset, the profile and the load are all cleaned up on every exit path --
# including Ctrl-C, which the earlier hand-written sweeps got wrong twice.
#
# RUNS FOR 90 SECONDS. perf_mode steps at 30 s and 60 s.
#
# Lowest-value item on the open list: burst limits govern brief excursions and
# the sustained limit is what matters for real behaviour.

set -uo pipefail   # deliberately not -e: a failure must still reach the cleanup

S=/sys/devices/platform/gigabyte_laptop
PROFILE=/sys/firmware/acpi/platform_profile
RAPL=/sys/class/powercap/intel-rapl:0
E=$RAPL/energy_uj
SECONDS_TOTAL=90

die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$S" ] || die "driver not loaded: $S does not exist"
[ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)" = 1 ] || \
	die "not on AC -- the firmware writes different limits on battery"
[ -r "$E" ] || die "cannot read $E"

# hwmon numbering is not stable across reboots, so find it by name
K=$(dirname "$(grep -l '^k10temp$' /sys/class/hwmon/*/name 2>/dev/null)" 2>/dev/null)

# The RAPL counter is finite and wraps. Observed on this machine: a single
# sample reported -65469 W, which is this exact range rolling over inside one
# second. Without the wrap correction that reads as a wild negative excursion.
#
# Validate it rather than defaulting to zero on failure: a zero range makes the
# correction add nothing, so the negative sample survives and the very bug this
# exists to fix comes back silently.
MAXRANGE=$(cat "$RAPL/max_energy_range_uj" 2>/dev/null) ||
	die "cannot read $RAPL/max_energy_range_uj -- without the counter range a
wrapped sample cannot be corrected, and it would be reported as a large
negative wattage"
case $MAXRANGE in
*[!0-9]*|'') die "max_energy_range_uj is not a plain number: '$MAXRANGE'" ;;
esac
(( MAXRANGE > 0 )) || die "max_energy_range_uj is $MAXRANGE; need a positive range"

if command -v stress-ng >/dev/null; then
	# Deliberately longer than the sampling run, so the load never ends first.
	LOAD=(stress-ng --cpu 0 --cpu-method matrixprod --metrics-brief -t $((SECONDS_TOTAL + 10))s)
	echo "load: stress-ng matrixprod on all cores"
else
	cat <<-EOF
	stress-ng is not installed. Install it for a genuinely heavy load:
	    sudo dnf install stress-ng

	Falling back to a repeated openssl AES benchmark. It beats yes(1) but may
	still not reach 65 W, in which case this run proves nothing either way.
	EOF
	# openssl speed is a FINITE benchmark -- it runs its fixed iterations and
	# exits, which would leave the machine idle partway through the sweep. The
	# while loop is what keeps the load up for the whole period.
	LOAD=(bash -c 'for _ in $(seq '"$(nproc)"'); do
			while :; do openssl speed -evp aes-256-gcm >/dev/null 2>&1; done &
		done; wait')
fi

# Every saved value is checked before anything is changed. An unreadable node
# gives an empty string under `set -u` without -e, and the cleanup would then
# write nothing and report a restore that did not happen.
save() {   # save <path> <description>
	local v
	v=$(cat "$1" 2>/dev/null) ||
		die "cannot read $1 ($2) -- refusing to change settings without a restore path"
	[ -n "$v" ] ||
		die "$1 ($2) read back empty -- refusing to change settings without a restore path"
	printf '%s' "$v"
}

PRESET_WAS=$(save "$S/fan_preset" "fan preset")           || exit 1
PROFILE_WAS=$(save "$PROFILE" "platform profile")         || exit 1
# This script writes perf_mode directly, which also moves power_preset to match
# -- so both have to be saved. The first version restored only the fan preset
# and the profile, and left the machine pinned at the top GPU tier with
# power_preset=boost. Third time a sweep here failed to put something back.
POWER_PRESET_WAS=$(save "$S/power_preset" "power preset") || exit 1
LOAD_PID=""
LOAD_LOG=$(mktemp) || die "cannot create a temporary file for the load's output"

# Kill only our own descendants, found by walking the process tree. The earlier
# version used `pkill -f stress-ng` and `pkill -f 'openssl speed'`, which would
# also have killed a stress-ng or openssl the user happened to be running for
# their own reasons.
kill_tree() {
	local parent=$1 child
	for child in $(ps -o pid= --ppid "$parent" 2>/dev/null); do
		kill_tree "$child"
	done
	kill -TERM "$parent" 2>/dev/null
}

cleaned=0
cleanup() {
	[ "$cleaned" -eq 1 ] && return
	cleaned=1
	[ -n "$LOAD_PID" ] && kill_tree "$LOAD_PID"
	# power_preset last of the three: writing it re-applies the tier, so it
	# must land after the profile it may need to read.
	echo "$PROFILE_WAS"       > "$PROFILE"           2>/dev/null
	echo "$PRESET_WAS"        > "$S/fan_preset"      2>/dev/null
	echo "$POWER_PRESET_WAS"  > "$S/power_preset"    2>/dev/null
	sleep 3
	printf '\n== restored ==\n'
	printf '   fan_preset=%s power_preset=%s platform_profile=%s\n' \
		"$(cat "$S/fan_preset")" "$(cat "$S/power_preset")" "$(cat "$PROFILE")"
	printf '   perf_mode=%s fan_mode=%s\n' \
		"$(cat "$S/perf_mode")" "$(cat "$S/fan_mode")"
	[ -n "${LOAD_LOG:-}" ] && rm -f "$LOAD_LOG"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# Every write is checked. A rejected fan_preset or perf_mode write would leave
# the samples labelled with a mode the machine is not in, which is worse than
# no data.
set_node() {   # set_node <path> <value>
	echo "$2" > "$1" 2>/dev/null ||
		die "write of '$2' to $1 was rejected -- stopping rather than sampling a
machine that is not in the state the output would claim"
}

set_node "$S/fan_preset" gaming
set_node "$S/perf_mode"  0
sleep 3

# Keep the load's output. If it dies early -- which is exactly what the finite
# openssl fallback used to do -- the samples silently become an idle run, and
# that is how this test produced a wrong answer the first time.
"${LOAD[@]}" >"$LOAD_LOG" 2>&1 &
LOAD_PID=$!

load_alive() { kill -0 "$LOAD_PID" 2>/dev/null; }

report_dead_load() {
	local status
	wait "$LOAD_PID" 2>/dev/null; status=$?
	cat >&2 <<-EOF

	THE LOAD EXITED EARLY, after ${1}s of ${SECONDS_TOTAL}. Exit status $status.
	Every sample from here on would be an idle machine reported as a loaded run,
	so this stops now. Its output:
	EOF
	sed 's/^/  /' "$LOAD_LOG" >&2
	die "load did not survive the sampling period"
}

cat <<EOF

RUNS FOR ${SECONDS_TOTAL} SECONDS. perf_mode steps at 30 s and 60 s.
Ctrl-C stops the load and restores everything.

EOF
printf '%4s %5s %6s %7s %5s\n' sec mode pkgW clkMHz k10C

# Microseconds since the epoch, without forking date(1). uJ divided by us is
# exactly watts, so the units cancel and no scaling constant is needed.
now_us() { local t=${EPOCHREALTIME/./}; echo "${t:-0}"; }

prev_uj=$(cat "$E")
prev_us=$(now_us)

for t in $(seq 1 "$SECONDS_TOTAL"); do
	sleep 1

	load_alive || report_dead_load "$t"

	now_uj=$(cat "$E")
	now_us=$(now_us)

	d_uj=$((now_uj - prev_uj))
	# Wrap correction. The counter is unsigned and finite, so a negative delta
	# means it rolled over between the two reads, not that energy was returned.
	(( d_uj < 0 )) && d_uj=$((d_uj + MAXRANGE))

	d_us=$((now_us - prev_us))
	# The interval is not exactly one second: the sleep is one second plus the
	# time these reads take. Dividing by the measured elapsed time rather than
	# assuming 1 s is what keeps the wattage honest -- assuming it over-reports.
	(( d_us <= 0 )) && d_us=1

	printf '%4d %5s %6d %7d %5d\n' \
		"$t" "$(cat "$S/perf_mode")" \
		"$((d_uj / d_us))" \
		"$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))" \
		"$(( $(cat "$K/temp1_input" 2>/dev/null || echo 0) / 1000 ))"

	prev_uj=$now_uj
	prev_us=$now_us

	case $t in
	30) set_node "$S/perf_mode" 1 ;;
	60) set_node "$S/perf_mode" 2 ;;
	esac
done

cat <<'EOF'

How to read it:

  pkgW never exceeds ~65 W
      The load still is not heavy enough. The burst limits remain untested,
      and that is the end of what can be learned without a heavier load.

  pkgW exceeds 65 W and clkMHz is flat across all three modes
      The burst limits are not enforced either. The APU half of perf_mode does
      nothing at all, and that item closes completely.

  pkgW exceeds 65 W and clkMHz DROPS in mode 0 but not in mode 2
      The burst limits ARE enforced. perf_mode does control APU power under
      short excursions, and the sustained-limit result stands alongside it
      rather than replacing it. That would be a real finding.
EOF
