#!/bin/bash
# Which way round is dynamic_boost, and does it do anything?
#
# The node reads and writes 0 = off / 1 = on, and the driver inverts before
# sending, so a node write of 1 reaches the firmware as 0. Reading WMBD
# Case (0xE7) in GAMING-A16-5TH-DSDT.dsl:9524, the two firmware branches are:
#
#   raw 0  ->  DBAC = 1, DBDC = 1, AMAT = 0,     PPAB = 0
#   raw 1  ->  DBAC = 0, DBDC = 0, AMAT = LMAT,  PPAB = 1
#
# AMAT is 0x78 (120) in every perf_mode branch and AMIT is 0xFF88, which is
# -120 signed -- a symmetric budget Dynamic Boost is allowed to shift between
# the CPU and the GPU. Zeroing it should stop the shifting; restoring it from
# LMAT should allow it.
#
# That is a mechanism argument, not an argument from field names, and it
# suggests the node is backwards: node 1 reaches the firmware as raw 0, which
# is the branch that ZEROES the budget. THIS SCRIPT DOES NOT ASSUME THAT. It
# reports which node value quietens the limit and lets the measurement decide.
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
restore() {
	[ "$restored" -eq 1 ] && return
	restored=1
	echo "$BOOST_WAS" > "$P/dynamic_boost" 2>/dev/null
	printf '\n== restored ==\n  dynamic_boost=%s perf_mode=%s gpu_boost=%s\n' \
		"$(cat "$P/dynamic_boost")" "$(cat "$P/perf_mode")" "$(cat "$P/gpu_boost")"
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

say "conditions"
printf '  perf_mode=%s gpu_boost=%s power_preset=%s dynamic_boost=%s\n' \
	"$(cat "$P/perf_mode")" "$(cat "$P/gpu_boost")" \
	"$(cat "$P/power_preset")" "$BOOST_WAS"
printf '  GPU: %s\n' "$(nvidia-smi --query-gpu=pstate,utilization.gpu,power.draw --format=csv,noheader)"
echo "  Each window is ${WINDOW}s. Three windows, so about $(( WINDOW * 3 / 60 + 1 )) minutes."

say "baseline, as found (dynamic_boost=$BOOST_WAS)"
read -r b_lo b_hi b_n <<< "$(sample "$WINDOW")"
printf '  min %s  max %s  distinct values %s\n' "$b_lo" "$b_hi" "$b_n"

for v in 1 0; do
	say "dynamic_boost = $v"
	echo "$v" > "$P/dynamic_boost" || { echo "  write FAILED"; continue; }
	sleep "$SETTLE"
	read -r lo hi n <<< "$(sample "$WINDOW")"
	printf '  min %s  max %s  distinct values %s\n' "$lo" "$hi" "$n"
	eval "n_$v=$n; lo_$v=$lo; hi_$v=$hi"
done

say "result"
printf '  as found (%s)      min %s  max %s  distinct %s\n' "$BOOST_WAS" "$b_lo" "$b_hi" "$b_n"
printf '  dynamic_boost 1    min %s  max %s  distinct %s\n' "$lo_1" "$hi_1" "$n_1"
printf '  dynamic_boost 0    min %s  max %s  distinct %s\n' "$lo_0" "$hi_0" "$n_0"
echo

if [ "$b_n" -le 1 ] && [ "$n_1" -le 1 ] && [ "$n_0" -le 1 ]; then
	cat <<-'EOF'
	INCONCLUSIVE -- the limit never moved in any window, including the
	baseline. Both "the toggle quietened it" and "there was nothing to
	quieten" predict exactly this, so it distinguishes nothing.

	Give the discrete GPU sustained work and re-run. In hybrid mode an idle
	card sits at P8 and nothing arbitrates.
	EOF
elif [ "$n_1" -le 1 ] && [ "$n_0" -gt 1 ]; then
	cat <<-'EOF'
	THE NODE IS INVERTED. Writing 1 ("on") held the limit still; writing 0
	("off") let it wander. So node 1 reaches the firmware as raw 0, which is
	the branch that zeroes AMAT -- and zeroing the budget is what DISABLES
	boost. The driver's !enable inversion in dynamic_boost_store() and the
	"write 0 to enable" comment on DYN_BOOST are both the wrong way round.

	Fix: drop the inversion, so the node value is sent unchanged.
	EOF
elif [ "$n_0" -le 1 ] && [ "$n_1" -gt 1 ]; then
	cat <<-'EOF'
	THE NODE IS CORRECT AS SHIPPED. Writing 0 ("off") held the limit still
	and writing 1 ("on") let it wander, which is what the node's documented
	sense promises. The inversion in dynamic_boost_store() is right and the
	fork's testing on the CWH was right. Record it and close the question.
	EOF
else
	cat <<-'EOF'
	UNCLEAR -- both settings showed spread, so neither pinned the limit.
	dynamic_boost may not be the thing driving these excursions at all;
	amd_pmf is the other candidate, since it is a second power manager.
	Record the numbers and do not read a direction out of them.
	EOF
fi
