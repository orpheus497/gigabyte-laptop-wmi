#!/bin/bash
# Which way round is dynamic_boost, and does it do anything?
#
# The node reads and writes 0 = off / 1 = on and passes the value through
# UNCHANGED. Reading WMBD Case (0xE7) in GAMING-A16-5TH-DSDT.dsl:9524, the two
# firmware branches are:
#
#   raw 0  ->  DBAC = 1, DBDC = 1, AMAT = 0,     PPAB = 0
#   raw 1  ->  DBAC = 0, DBDC = 0, AMAT = LMAT,  PPAB = 1
#
# AMAT is 0x78 (120) in every perf_mode branch and AMIT is 0xFF88, which is
# -120 signed -- a symmetric budget Dynamic Boost is allowed to shift between
# the CPU and the GPU. Zeroing it should stop the shifting; restoring it from
# LMAT should allow it.
#
# So the node's documented sense and the firmware's branches now agree: node 1
# reaches the firmware as raw 1, which restores the budget and lets the limit
# move; node 0 zeroes it and should hold the limit still.
#
# HISTORY, because this script is what found the bug and the bug is now fixed.
# dynamic_boost_store() used to send !enable, so a node write of 1 arrived as
# raw 0 -- the branch that ZEROES the budget -- and the node's "on" switched
# boost off. This test measured exactly that: node 1 pinned the limit at the
# tier and node 0 let it wander. The write inversion was then removed and a
# read inversion added, because WMBC 0xE7 returns DBAC, which is a DISABLE
# flag. Re-running this script against the fixed driver should therefore give
# the OPPOSITE result -- node 0 quiet, node 1 wandering -- and that is the
# "CORRECT AS SHIPPED" verdict below, not a regression.
#
# THIS SCRIPT STILL ASSUMES NOTHING. It reports which node value quietens the
# limit and lets the measurement decide.
#
# WHY THE LIMIT IS THE OBSERVABLE: enforced.power.limit is the limit Dynamic
# Boost is currently arbitrating. With boost active it wanders above the tier's
# base; with the budget zeroed it should sit still at the base. So the spread
# over a window -- not the value -- is what distinguishes the two settings.
#
# RUN THIS WHILE THE LIMIT IS ALREADY WANDERING. Check first:
#
#   for i in $(seq 30); do nvidia-smi --query-gpu=enforced.power.limit \
#       --format=csv,noheader; sleep 1; done | sort -u
#
# More than one value means arbitration is active and this test can work. A
# single value means there is nothing for a toggle to quieten, and the result
# would be "no spread either way", which distinguishes nothing -- the same trap
# that produced the temp2 error. Give the GPU work to do and try again.
#
# Usage: sudo bash tests/test-dynamic-boost.sh [seconds-per-window]
#
# Restores dynamic_boost on every exit path, including Ctrl-C.

set -uo pipefail   # deliberately not -e: a failure must still reach the restore

P=/sys/devices/platform/gigabyte_laptop
WINDOW=${1:-45}
SETTLE=5

die() { echo "$*" >&2; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# Validate the window BEFORE any state change. A zero or non-numeric argument
# made `sample()` run `seq` with no valid count, so every window recorded zero
# samples; the empty counts then satisfied "at most one distinct value" and the
# script printed "the limit never moved in any window" -- a false verdict, and
# printed only after dynamic_boost had already been toggled three times.
case "$WINDOW" in
	''|*[!0-9]*) die "window must be a whole number of seconds, got: $WINDOW" ;;
esac
[ "$WINDOW" -ge 10 ] || die "window of ${WINDOW}s is too short to see an excursion; use 30 or more"

[ -d "$P" ] || die "driver not loaded: $P does not exist"
[ -e "$P/dynamic_boost" ] || die "dynamic_boost is absent: not Gigabyte Gaming firmware"
command -v nvidia-smi >/dev/null || die "needs nvidia-smi to read the power limit"
[ "$(cat /sys/class/power_supply/ACAD/online 2>/dev/null)" = 1 ] ||
	die "not on AC -- the firmware withholds the DC power table, so nothing arbitrates"

# sample <seconds> -> "min max distinct"
sample() {
	local i v lo="" hi="" vals=""
	for i in $(seq "$1"); do
		v=$(nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader)
		v=${v%% *}
		[ -z "$lo" ] && { lo=$v; hi=$v; }
		awk -v a="$v" -v b="$lo" 'BEGIN{exit !(a<b)}' && lo=$v
		awk -v a="$v" -v b="$hi" 'BEGIN{exit !(a>b)}' && hi=$v
		vals="$vals$v
"
		sleep 1
	done
	printf '%s %s %s' "$lo" "$hi" "$(printf '%s' "$vals" | sort -u | grep -c .)"
}

BOOST_WAS=$(cat "$P/dynamic_boost")
restored=0
RESTORE_OK=1
# Same helper and RESTORE_OK convention as test-gpu-power.sh and
# test-apu-burst.sh, so all three scripts report a failed restore the same way.
# This one used to discard the status and stderr and print "== restored ==="
# regardless, which left dynamic_boost wherever the last window put it while
# the output said otherwise.
put_back() {   # put_back <value> <path> <label>
	if ! echo "$1" > "$2" 2>/dev/null; then
		echo "  RESTORE FAILED: $3 could not be set back to '$1'" >&2
		RESTORE_OK=0
	fi
}
restore() {
	[ "$restored" -eq 1 ] && return
	restored=1
	put_back "$BOOST_WAS" "$P/dynamic_boost" dynamic_boost
	if [ "$RESTORE_OK" -eq 1 ]; then
		printf '\n== restored ==\n'
	else
		printf '\n== RESTORE INCOMPLETE -- check the values below by hand ==\n' >&2
	fi
	printf '  dynamic_boost=%s perf_mode=%s gpu_boost=%s\n' \
		"$(cat "$P/dynamic_boost")" "$(cat "$P/perf_mode")" "$(cat "$P/gpu_boost")"
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

say "conditions"
printf '  perf_mode=%s gpu_boost=%s power_preset=%s dynamic_boost=%s\n' \
	"$(cat "$P/perf_mode")" "$(cat "$P/gpu_boost")" \
	"$(cat "$P/power_preset")" "$BOOST_WAS"
printf '  GPU: %s\n' "$(nvidia-smi --query-gpu=pstate,utilization.gpu,power.draw --format=csv,noheader)"
echo "  Four windows of ${WINDOW}s: as-found, 1, 0, then as-found again as a"
echo "  CONTROL. About $(( (WINDOW * 4 + 60) / 60 )) minutes."

# A1 -- as found
say "window 1/4: baseline, as found (dynamic_boost=$BOOST_WAS)"
read -r a1_lo a1_hi a1_n <<< "$(sample "$WINDOW")"
printf '  min %s  max %s  distinct values %s\n' "$a1_lo" "$a1_hi" "$a1_n"

# B1, B0
for v in 1 0; do
	say "window $(( v == 1 ? 2 : 3 ))/4: dynamic_boost = $v"
	# STOP on a failed write rather than carrying on. The old `continue` left
	# n_$v, lo_$v and hi_$v unset for that window, and the verdict below then
	# compared a window that was never measured -- the worst possible outcome
	# for a test whose whole job is distinguishing which setting moved the
	# limit. If the value cannot be set, there is nothing to measure.
	if ! echo "$v" > "$P/dynamic_boost"; then
		die "could not write dynamic_boost=$v -- no window to measure, aborting"
	fi
	sleep "$SETTLE"
	read -r lo hi n <<< "$(sample "$WINDOW")"
	printf '  min %s  max %s  distinct values %s\n' "$lo" "$hi" "$n"
	# printf -v rather than eval: these are integers from sample() so eval was
	# not an injection risk, but it needs no interpreter pass at all.
	printf -v "n_$v"  '%s' "$n"
	printf -v "lo_$v" '%s' "$lo"
	printf -v "hi_$v" '%s' "$hi"
done

# A2 -- the control. This is the window that makes the test mean anything:
# the excursions are INTERMITTENT, so a quiet window under a test setting
# proves nothing on its own. Only a RETURN of the wandering once the original
# setting is restored shows that the setting was what stopped it.
say "window 4/4: CONTROL -- back to as-found (dynamic_boost=$BOOST_WAS)"
# Check this write too. The control is the window that makes the whole test
# mean anything -- every verdict below gates on a2_n -- so a silent failure
# here would leave window 4 measuring whatever window 3 set, and the result
# would read as "the wandering did not return" when nothing was restored.
if ! echo "$BOOST_WAS" > "$P/dynamic_boost"; then
	die "could not restore dynamic_boost=$BOOST_WAS for the control window;
no verdict is possible without it"
fi
sleep "$SETTLE"
read -r a2_lo a2_hi a2_n <<< "$(sample "$WINDOW")"
printf '  min %s  max %s  distinct values %s\n' "$a2_lo" "$a2_hi" "$a2_n"

say "result"
printf '  1 as-found (%s)   min %s  max %s  distinct %s\n' "$BOOST_WAS" "$a1_lo" "$a1_hi" "$a1_n"
printf '  2 boost = 1       min %s  max %s  distinct %s\n' "$lo_1" "$hi_1" "$n_1"
printf '  3 boost = 0       min %s  max %s  distinct %s\n' "$lo_0" "$hi_0" "$n_0"
printf '  4 as-found again  min %s  max %s  distinct %s   <- control\n' "$a2_lo" "$a2_hi" "$a2_n"
echo

# Did anything wander at all?
if (( a1_n <= 1 && n_1 <= 1 && n_0 <= 1 && a2_n <= 1 )); then
	cat <<-'EOF'
	INCONCLUSIVE -- the limit never moved in any window, control included.
	Both "the toggle quietened it" and "there was nothing to quieten" predict
	exactly this, so it distinguishes nothing.

	Give the discrete GPU sustained work and re-run. An idle card at P8 does
	not arbitrate.
	EOF
elif (( n_1 <= 1 && n_0 > 1 && a2_n > 1 )); then
	cat <<-'EOF'
	THE NODE IS INVERTED AGAIN -- which would mean the fix is wrong, so check
	before acting. Writing 1 ("on") held the limit still; writing 0 ("off") let
	it wander, and the control confirmed the wandering returns.

	dynamic_boost_store() currently passes the value through unchanged, so node
	1 arrives as raw 1, the branch that RESTORES AMAT from LMAT. That should
	let the limit move, and this result says it did the opposite.

	Before changing anything: confirm the driver really is the fixed build
	(check that dynamic_boost_store does NOT send !enable) and re-run once. A
	single inverted run against the fixed driver is more likely a stale module
	than a wrong fix.
	EOF
elif (( n_0 <= 1 && n_1 > 1 && a2_n > 1 )); then
	cat <<-'EOF'
	THE NODE IS CORRECT AS SHIPPED. Writing 0 ("off") held the limit still and
	writing 1 ("on") let it wander, which is what the node's documented sense
	promises, and the control confirmed the wandering returns. This is the
	expected result against the fixed driver. Record it and close the question.
	EOF
elif (( n_1 <= 1 && n_0 <= 1 && a1_n > 1 && a2_n > 1 )); then
	cat <<-'EOF'
	WRITING 0xE7 PINS THE LIMIT, EITHER WAY -- and the control is what makes
	that readable. Both test settings held the limit still, and the wandering
	RETURNED once the original setting was restored. So it is the write
	itself, not the value, that quietens arbitration.

	Both firmware branches end in Notify (NPCF, 0xC0), so the likely mechanism
	is the notify making the consumer re-read and settle at the tier base,
	rather than AMAT's value mattering. AMAT is therefore NOT what drives
	these excursions.

	This says nothing about which direction means "boost on" -- that question
	needs an observable other than the limit's spread. Record it as a property
	of 0xE7 and leave the direction open.
	EOF
elif (( n_1 <= 1 && n_0 <= 1 && a2_n <= 1 && a1_n > 1 )); then
	cat <<-'EOF'
	INCONCLUSIVE, AND THE CONTROL IS WHY. The baseline wandered, both test
	settings were quiet -- and so was the control, with the original setting
	restored. The wandering therefore stopped on its own partway through, and
	nothing here can be credited to the writes.

	That is the intermittency this hardware is already known for: excursions
	come in bursts with long quiet stretches. A single quiet window is not
	evidence a setting caused it.

	Re-run with a longer window (the first argument is seconds, try 120) or
	when the limit is wandering more continuously. Check first:
	  for i in $(seq 60); do nvidia-smi --query-gpu=enforced.power.limit \
	      --format=csv,noheader; sleep 1; done | sort | uniq -c
	EOF
elif (( n_1 <= 1 && n_0 <= 1 && a1_n <= 1 && a2_n > 1 )); then
	cat <<-'EOF'
	INCONCLUSIVE -- the wandering only STARTED in the control window. The
	baseline was quiet, both test settings were quiet, and the limit began
	moving only after the original setting was restored at the end.

	Nothing can be credited to the writes: a burst that happens to begin in
	the last window produces exactly this, and so would a setting that
	un-pinned the limit. The two predict the same output, which distinguishes
	nothing.

	Re-run once the limit is already wandering -- check before starting, and
	do not start until more than one value appears:
	  for i in $(seq 60); do nvidia-smi --query-gpu=enforced.power.limit \
	      --format=csv,noheader; sleep 1; done | sort | uniq -c
	EOF
elif (( a2_n <= 1 && ( (n_1 <= 1 && n_0 > 1) || (n_0 <= 1 && n_1 > 1) ) )); then
	cat <<-'EOF'
	SUGGESTIVE BUT NOT ESTABLISHED -- one setting was quiet and the other
	wandered, which looks like a direction, but THE CONTROL STAYED QUIET.

	That is the one reading this test exists to refuse. With the original
	setting restored the wandering did not return, so the quiet window under
	the test setting may simply be where the burst ended. A direction read out
	of this is the same error as a measurement taken where both hypotheses
	predict the same output.

	Re-run with a longer window (the first argument is seconds, try 120), or
	when the limit is wandering more continuously. Do not record a direction
	from this run.
	EOF
else
	cat <<-'EOF'
	NO DIRECTION READABLE. Both test settings let the limit wander, so neither
	pinned it and 0xE7 is not controlling these excursions. amd_pmf is the
	other candidate, being a second power manager. Record the numbers and do
	not read a direction out of them.
	EOF
fi
