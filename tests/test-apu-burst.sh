#!/bin/bash
# Which of the APU's three programmed power limits actually bind?
#
# Each perf_mode writes three figures through ECPT. On AC:
#
#   mode   0x30 SPL   0x32 sPPT   0x34 fPPT
#    0        45 W       65 W       65 W
#    1        65 W       65 W       80 W
#    2        70 W       80 W       80 W
#
# Measured twice on a GAMING A16 5TH, the plateaus are 65 / 65 / 80 W -- the
# 0x32 column exactly. Mode 1 is what discriminates: it is the only mode where
# 0x32 and 0x34 differ, and it sits at 65, so 0x32 is the ceiling and 0x34's
# enforcement is unproven.
#
# What remains open is 0x30, the SUSTAINED limit, and the sweep mode cannot
# answer it. A sustained limit is defined over a time window; holding each mode
# for 30 s shows only that the part was inside its burst allowance, not that
# 0x30 is ignored. That needs --hold.
#
# Usage:
#   sudo bash tests/test-apu-burst.sh                 sweep 0->1->2, 90 s
#   sudo bash tests/test-apu-burst.sh --hold 0        hold mode 0 for 5 min
#   sudo bash tests/test-apu-burst.sh --hold 0 600    ... for 10 min
#
# --hold is the one that answers the open question. Mode 0 is the mode to use:
# its SPL is 45 W against a 65 W sPPT, so if the sustained limit engages at all
# the step down is 20 W and unmistakable. The sweep mode is now only a
# regression check on the sPPT decode.
#
# Needs mains -- the firmware writes a different, lower set of limits on
# battery. Cooling is pinned to gaming so the fans are not a variable, and the
# fan preset, power preset, profile and load are all put back on every exit
# path including Ctrl-C.

set -uo pipefail   # deliberately not -e: a failure must still reach the cleanup

S=/sys/devices/platform/gigabyte_laptop
PROFILE=/sys/firmware/acpi/platform_profile
RAPL=/sys/class/powercap/intel-rapl:0
E=$RAPL/energy_uj

MODE_HOLD=""          # set by --hold
SECONDS_TOTAL=90      # sweep default; --hold overrides
BASELINE_WINDOW=30    # seconds of --hold used to establish the starting plateau
STEP_FRACTION=88      # a later average below this percent of baseline is a step

die() { echo "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--hold)
		MODE_HOLD=${2:-}
		case $MODE_HOLD in
		0|1|2) ;;
		*) die "--hold needs a mode of 0, 1 or 2" ;;
		esac
		SECONDS_TOTAL=300
		shift 2
		case ${1:-} in
		''|--*) ;;
		*[!0-9]*) die "hold duration must be a number of seconds" ;;
		*) SECONDS_TOTAL=$1; shift ;;
		esac
		;;
	-h|--help)
		sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
		exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

(( SECONDS_TOTAL >= 10 )) || die "duration must be at least 10 s"
[ -z "$MODE_HOLD" ] || (( SECONDS_TOTAL > BASELINE_WINDOW + 30 )) ||
	die "a --hold shorter than $((BASELINE_WINDOW + 30))s cannot show a step after the baseline window"

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$S" ] || die "driver not loaded: $S does not exist"
[ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)" = 1 ] || \
	die "not on AC -- the firmware writes different limits on battery"
[ -r "$E" ] || die "cannot read $E"

# hwmon numbering is not stable across reboots, so find it by name
K=$(dirname "$(grep -l '^k10temp$' /sys/class/hwmon/*/name 2>/dev/null)" 2>/dev/null)

# The RAPL counter is finite and wraps. Observed on this machine: a single
# sample reported -65469 W, which is this exact range rolling over inside one
# second. Validate rather than defaulting to zero on failure -- a zero range
# makes the correction add nothing, reinstating the bug it exists to fix.
MAXRANGE=$(cat "$RAPL/max_energy_range_uj" 2>/dev/null) ||
	die "cannot read $RAPL/max_energy_range_uj -- without the counter range a
wrapped sample cannot be corrected, and it would be reported as a large
negative wattage"
case $MAXRANGE in
*[!0-9]*|'') die "max_energy_range_uj is not a plain number: '$MAXRANGE'" ;;
esac
(( MAXRANGE > 0 )) || die "max_energy_range_uj is $MAXRANGE; need a positive range"

if command -v stress-ng >/dev/null; then
	# Deliberately longer than the run, so the load never ends first.
	LOAD=(stress-ng --cpu 0 --cpu-method matrixprod --metrics-brief -t $((SECONDS_TOTAL + 15))s)
	echo "load: stress-ng matrixprod on all cores"
else
	cat <<-EOF
	stress-ng is not installed. Install it for a genuinely heavy load:
	    sudo dnf install stress-ng

	Falling back to a repeated openssl AES benchmark. It beats yes(1) but may
	still not reach 65 W, in which case this run proves nothing either way.
	EOF
	# openssl speed is a FINITE benchmark -- it runs its fixed iterations and
	# exits, which would leave the machine idle partway through. The while loop
	# is what keeps the load up for the whole period.
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
POWER_PRESET_WAS=$(save "$S/power_preset" "power preset") || exit 1
LOAD_PID=""
LOAD_LOG=$(mktemp) || die "cannot create a temporary file for the load's output"

# Kill only our own descendants, found by walking the process tree. Using
# `pkill -f stress-ng` would also kill a stress-ng the caller was running.
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
	# power_preset last: writing it re-applies the tier, so it must land after
	# the profile it may need to read.
	echo "$PROFILE_WAS"       > "$PROFILE"        2>/dev/null
	echo "$PRESET_WAS"        > "$S/fan_preset"   2>/dev/null
	echo "$POWER_PRESET_WAS"  > "$S/power_preset" 2>/dev/null
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

START_MODE=${MODE_HOLD:-0}
set_node "$S/fan_preset" gaming
set_node "$S/perf_mode"  "$START_MODE"
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

echo
if [ -n "$MODE_HOLD" ]; then
	cat <<-EOF
	HOLDING perf_mode $MODE_HOLD FOR ${SECONDS_TOTAL} SECONDS ($((SECONDS_TOTAL / 60)) min).
	Looking for a step DOWN in pkgW, which is what a sustained limit engaging
	looks like. The first ${BASELINE_WINDOW}s establish the baseline plateau.
	Ctrl-C stops the load and restores everything.
	EOF
else
	cat <<-EOF
	SWEEPING 0 -> 1 -> 2 OVER ${SECONDS_TOTAL} SECONDS. Steps at 30 s and 60 s.
	This is a regression check on the sPPT decode. It canNOT answer whether the
	sustained limit binds -- use --hold 0 for that.
	Ctrl-C stops the load and restores everything.
	EOF
fi
echo
printf '%4s %5s %6s %7s %5s\n' sec mode pkgW clkMHz k10C

# Microseconds since the epoch, without forking date(1). uJ divided by us is
# exactly watts, so the units cancel and no scaling constant is needed.
now_us() { local t=${EPOCHREALTIME/./}; echo "${t:-0}"; }

prev_uj=$(cat "$E")
prev_us=$(now_us)

base_sum=0 base_n=0          # the baseline plateau, --hold only
tail_sum=0 tail_n=0          # a rolling 10-sample tail to compare against it
step_at=""
peak=0

for t in $(seq 1 "$SECONDS_TOTAL"); do
	sleep 1

	load_alive || report_dead_load "$t"

	now_uj=$(cat "$E")
	now_us=$(now_us)

	d_uj=$((now_uj - prev_uj))
	# Wrap correction: the counter is unsigned and finite, so a negative delta
	# means it rolled over between the reads, not that energy was returned.
	(( d_uj < 0 )) && d_uj=$((d_uj + MAXRANGE))

	d_us=$((now_us - prev_us))
	# The interval is one second plus the time these reads take. Dividing by
	# measured elapsed time rather than assuming 1 s keeps the wattage honest.
	(( d_us <= 0 )) && d_us=1
	w=$((d_uj / d_us))

	printf '%4d %5s %6d %7d %5d\n' \
		"$t" "$(cat "$S/perf_mode")" "$w" \
		"$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) / 1000 ))" \
		"$(( $(cat "$K/temp1_input" 2>/dev/null || echo 0) / 1000 ))"

	prev_uj=$now_uj
	prev_us=$now_us

	if [ -n "$MODE_HOLD" ]; then
		(( w > peak )) && peak=$w
		if (( t <= BASELINE_WINDOW )); then
			base_sum=$((base_sum + w)); base_n=$((base_n + 1))
			# Say when the baseline closes, so the run visibly changes phase
			# rather than looking like a sweep that forgot to step.
			if (( t == BASELINE_WINDOW )); then
				printf '  -- baseline set: %d W over %ds. Now watching for a step below %d W.\n' \
					"$((base_sum / base_n))" "$BASELINE_WINDOW" \
					"$(( (base_sum / base_n) * STEP_FRACTION / 100 ))"
			fi
		else
			tail_sum=$((tail_sum + w)); tail_n=$((tail_n + 1))
			if (( tail_n == 10 )); then
				base_avg=$((base_sum / base_n))
				tail_avg=$((tail_sum / 10))
				if [ -n "$step_at" ]; then
					# A step was already reported. Keep printing the windows
					# so the plateau after it is visible, but do not call them
					# "no step" -- the step stands, and re-reporting it every
					# window would be just as misleading.
					printf '  -- %ds: last 10 averaged %d W (stepped at %ds) (%ds left)\n' \
						"$t" "$tail_avg" "$step_at" "$((SECONDS_TOTAL - t))"
				elif (( tail_avg * 100 < base_avg * STEP_FRACTION )); then
					step_at=$t
					printf '  ^^ STEP DOWN: 10-sample average %d W against a %d W baseline\n' \
						"$tail_avg" "$base_avg"
				else
					# Print every comparison, not only the one that fires.
					# Otherwise the detector is invisible and the run is
					# indistinguishable from a sweep that is not stepping.
					printf '  -- %ds: last 10 averaged %d W vs %d W baseline, no step (%ds left)\n' \
						"$t" "$tail_avg" "$base_avg" "$((SECONDS_TOTAL - t))"
				fi
				tail_sum=0; tail_n=0
			fi
		fi
	else
		case $t in
		30) set_node "$S/perf_mode" 1 ;;
		60) set_node "$S/perf_mode" 2 ;;
		esac
	fi
done

echo
if [ -n "$MODE_HOLD" ]; then
	base_avg=$(( base_n > 0 ? base_sum / base_n : 0 ))
	echo "== result: perf_mode $MODE_HOLD held for ${SECONDS_TOTAL}s =="
	printf '   baseline plateau (first %ds) : %d W\n' "$BASELINE_WINDOW" "$base_avg"
	printf '   peak observed                : %d W\n' "$peak"
	if [ -n "$step_at" ]; then
		cat <<-EOF

		A STEP DOWN was detected at ${step_at}s.

		That is a sustained power limit engaging: the part ran at its burst
		allowance, the window expired, and it was pulled back. Record the
		settling wattage and the time -- together they give the SPL value and
		its time constant, neither of which was known. The firmware's 0x30
		figure for this mode is the number the plateau should now match.
		EOF
	else
		printf '\n\tNO step down over %ss.\n' "$SECONDS_TOTAL"
		# The "sustained limit is not enforced" conclusion only follows for
		# mode 0, and only if the load actually exceeded mode 0's 45 W SPL.
		# Held in any other mode the SPL is 65 or 70 W and this run says
		# nothing about it; and a load that never reached the ceiling cannot
		# show a ceiling binding, which is the error that made the first
		# sweep's verdict worthless.
		if [ "$MODE_HOLD" = 0 ] && (( base_avg > 45 )); then
			cat <<-EOF

			For mode 0 that is the interesting answer: 0x30 programs 45 W, the
			part held a ${base_avg} W plateau throughout, so the
			sustained limit is not being applied on any timescale this run
			covers. Saying "not enforced" is supported in a way the 30-second
			sweep never supported it.

			If this was a shorter hold, try a longer one before concluding --
			some sustained windows run to several minutes.
			EOF
		else
			cat <<-EOF

			Baseline $( ((base_avg > 0)) && echo "${base_avg} W" || echo "not established" ), peak ${peak} W, mode ${MODE_HOLD}.

			This does NOT establish that a sustained limit is unenforced. That
			conclusion needs mode 0, whose 45 W SPL sits well below the 65 W
			sPPT, AND a load that actually exceeded 45 W -- otherwise there was
			no ceiling for the part to be held against and nothing to observe.
			$( [ "$MODE_HOLD" = 0 ] || echo "Mode $MODE_HOLD programs a higher SPL; re-run with --hold 0." )
			EOF
		fi
	fi
else
	cat <<'EOF'
How to read the sweep:

  Plateaus at 65 / 65 / 80 W across modes 0 / 1 / 2
      The expected result, and a reproduction of the sPPT decode. Mode 1 is the
      load-bearing row: it is the only mode where sPPT (65) and fPPT (80)
      differ, so a 65 W plateau there says sPPT is the ceiling.

  Any other pattern
      Something has changed. Re-derive the ECPT constants from the firmware
      before trusting CLAUDE.md's table.

This mode says NOTHING about the sustained limit. Use --hold 0 for that.
EOF
fi
