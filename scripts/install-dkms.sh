#!/bin/bash
# Install the gigabyte-laptop driver through DKMS.
#
# dkms.conf ships PACKAGE_VERSION="@PKGVER@" as a template that the distro
# packaging substitutes, so loading the tarball straight into DKMS registers a
# module literally versioned "@PKGVER@". This substitutes it first, the same way
# the RPM spec and the PKGBUILD do.
#
# Under Secure Boot, DKMS signs the module with /var/lib/dkms/mok.key, which
# must already be enrolled. Nothing here enrolls a key.
#
# The module registers its platform device by hand and so has no modalias for
# udev to match. /etc/modules-load.d is therefore the only thing that brings it
# up at boot, and autoload is on by default.
#
# Usage: sudo bash scripts/install-dkms.sh [--no-autoload]
set -euo pipefail

NAME=gigabyte-laptop
# Take the version from the RPM spec, which is the project's canonical source,
# so DKMS registration cannot drift from packaging. Overridable, with the
# current value as a last resort if the spec is unreadable.
# `|| true` keeps a missing or unreadable spec from aborting the script under
# set -e and pipefail, which would make the fallback below unreachable.
# Capture only the version token, so trailing whitespace or a CRLF line ending
# in the spec cannot end up in a path.
VERSION="${VERSION:-$(sed -n 's/^Version:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
	"$(dirname "$0")/../pkg-files/rpm/gigabyte-laptop-dkms.spec" 2>/dev/null | head -1 || true)}"
VERSION="${VERSION:-0.2.0}"
SRC=/usr/src/$NAME-$VERSION
AUTOLOAD=1

for arg in "$@"; do
	case "$arg" in
		--no-autoload) AUTOLOAD=0 ;;
		--autoload) AUTOLOAD=1 ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

# Do not delete files a package still owns: rpm and dpkg would keep listing
# them and the next upgrade of that package would put them back. Ask the
# package manager first and hand the removal to it.
#
# This runs before anything is touched, and that ordering is the point. Placed
# later it was useless: module_unload had already dropped the old module and
# remove_dkms_version had already done `rm -rf /usr/src/aorus-laptop-$ver` --
# a package-owned tree -- so the machine was modified before the check could
# refuse. /usr/src/aorus-laptop-* is in the list for the same reason: it is
# what a package actually installs, and the first version of this check did not
# test it.
#
# The CURRENT name is gated too, and for the same reason rather than for
# symmetry: "Removing any previous registration" runs remove_dkms_version
# "$NAME" and then `rm -rf /var/lib/dkms/$NAME`, so a packaged
# gigabyte-laptop-dkms would have its source tree deleted and replaced with the
# smaller set this script installs, leaving rpm or dpkg listing files that no
# longer match. Gating it means the script refuses while that package is
# installed, which is the right answer: remove it through the package manager
# and then use the script, or keep using the package.
#
# /etc/modules-load.d/gigabyte-laptop.conf is deliberately NOT gated. The script
# overwrites it with identical content rather than deleting it, so it does not
# strand the package -- except under --no-autoload, which removes it; that is an
# explicit request and is left to the caller.
owner=
for f in /var/lib/dkms/aorus-laptop /etc/modules-load.d/aorus-laptop.conf \
         /usr/src/aorus-laptop-* \
         /var/lib/dkms/gigabyte-laptop /usr/src/gigabyte-laptop-*; do
	[ -e "$f" ] || continue
	if command -v rpm >/dev/null 2>&1; then
		owner=$(rpm -qf "$f" 2>/dev/null) && break
	fi
	if command -v dpkg >/dev/null 2>&1; then
		owner=$(dpkg -S "$f" 2>/dev/null | cut -d: -f1) && [ -n "$owner" ] && break
	fi
	owner=
done

if [ -n "$owner" ]; then
	echo "DKMS files here are still owned by a package: $owner" >&2
	echo "Remove it through the package manager rather than deleting its" >&2
	echo "files, then run this again:" >&2
	echo "   sudo dnf remove $owner        # or: sudo apt remove $owner" >&2
	exit 1
fi

# /proc/modules is the authoritative list of resident modules. Read it with no
# pipeline: `lsmod | grep -q` looks right but fails under pipefail, because
# grep -q exits on the first match and lsmod then dies of SIGPIPE.
module_loaded() {
	local m
	while read -r m _; do
		[ "$m" = "$1" ] && return 0
	done < /proc/modules
	return 1
}

# rmmod, not modprobe -r: modprobe resolves a module through its file, so it
# reports "not found" for a module that is resident after its .ko has gone.
module_unload() {
	module_loaded "$1" || return 0
	rmmod "$1"
}

# Delete a DKMS version's trees only once dkms itself has let go of it.
# `dkms remove --all` is what deletes the built module from /lib/modules, so
# removing the registration after it fails leaves a .ko that nothing manages
# and that modprobe cannot resolve by name. That is how the pre-rename
# aorus_laptop module came to be resident with no file behind it.
remove_dkms_version() {
	local name=$1 ver=$2 out still

	if out=$(dkms remove "$name/$ver" --all 2>&1); then
		rm -rf "/var/lib/dkms/$name/$ver" "/usr/src/$name-$ver"
		return 0
	fi

	# A version that was added but never built has nothing installed to
	# orphan, and dkms still reports failure removing it. Ask dkms what it
	# thinks rather than trusting the exit code: if the version is gone from
	# its view, cleanup is safe and aborting the installer would only wedge
	# it. No pipeline here, for the pipefail reason noted above.
	# Check the exit status separately. `$(... || true)` makes a *failed*
	# query indistinguishable from one that succeeded and found nothing, and
	# deleting trees on that basis would destroy a registration dkms simply
	# could not report on.
	if still=$(dkms status "$name/$ver" 2>/dev/null) && [ -z "$still" ]; then
		rm -rf "/var/lib/dkms/$name/$ver" "/usr/src/$name-$ver"
		return 0
	fi

	echo "$out" >&2
	echo "dkms could not remove $name/$ver and still lists it, so its" >&2
	echo "registration is left in place rather than orphaning the module it" >&2
	echo "installed. Inspect with: dkms status $name" >&2
	exit 1
}

cd "$(dirname "$0")/.."

# Build the module BEFORE removing anything, and abort if it fails.
#
# The removal below is destructive and irreversible by this script: it drops the
# DKMS registration, the built module and the /usr/src tree for the current
# version, and `dkms install` does not run until ~40 lines later. A compile
# error there used to leave the machine with no driver at all AND an
# /etc/modules-load.d entry from a previous run still asking for it, so the next
# boot failed in systemd-modules-load with nothing explaining why.
#
# Reordering the removal after the install is not the fix and was considered:
# DKMS will not hold two installs of one version, and the removal exists
# precisely to clear the "@PKGVER@" registration that `dkms ldtarball` leaves
# behind. Building first costs a couple of seconds and makes the failure
# non-destructive instead, which is the property that was missing.
#
# This is also the only compile gate there is -- CI packages the driver without
# ever compiling it -- so a syntax error reaches this script untouched.
#
# It builds in a temporary directory rather than in the checkout, because this
# script runs as root: an in-tree `make` would leave root-owned .o, .mod and
# Module.symvers files in the user's working copy, and `make clean` running as
# root is not a reliable undo for that.
echo "== Pre-flight build =="
KBUILD=/lib/modules/$(uname -r)/build
if [ ! -d "$KBUILD" ]; then
	echo "No kernel build tree at $KBUILD." >&2
	echo "DKMS cannot build without it. Install kernel-devel-matched (Fedora)" >&2
	echo "or linux-headers-\$(uname -r) (Debian/Ubuntu) and run this again." >&2
	echo "Nothing has been changed." >&2
	exit 1
fi
PREFLIGHT=$(mktemp -d)
trap 'rm -rf "$PREFLIGHT"' EXIT
install -m 644 Makefile gigabyte-laptop.c "$PREFLIGHT/"
if ! make -C "$KBUILD" M="$PREFLIGHT" modules >"$PREFLIGHT/log" 2>&1; then
	echo >&2
	echo "The module did not build, so NOTHING has been changed and your" >&2
	echo "installed driver is intact. The build log:" >&2
	echo >&2
	sed 's/^/    /' "$PREFLIGHT/log" | tail -40 >&2
	exit 1
fi
rm -rf "$PREFLIGHT"
trap - EXIT
echo "   builds clean"

# The driver was called aorus-laptop until the rename. Anything left from that
# name has to go, or the machine keeps a second DKMS tree, a second autoload
# entry and a stale module that still claims the WMI devices.
echo "== Removing the pre-rename aorus-laptop install, if present =="
# Both modules claim the same WMI devices and poke the same EC, so refuse to
# continue while the old one is still resident rather than install alongside it.
if ! module_unload aorus_laptop; then
	echo "Could not unload the old aorus_laptop module." >&2
	echo "It claims the same WMI devices as gigabyte-laptop, so installing" >&2
	echo "alongside it would leave two drivers on one EC. Close whatever is" >&2
	echo "using it, or reboot, then run this again." >&2
	exit 1
fi
if ! old_registered=$(dkms status aorus-laptop); then
	echo "\`dkms status aorus-laptop\` failed, so its registration cannot be" >&2
	echo "read. Refusing to delete /var/lib/dkms/aorus-laptop blind." >&2
	exit 1
fi
while read -r ver; do
	[ -n "$ver" ] || continue
	echo "   removing aorus-laptop/$ver"
	remove_dkms_version aorus-laptop "$ver"
done < <(printf '%s\n' "$old_registered" | sed -n "s|^aorus-laptop/\([^,:]*\).*|\1|p" | sort -u)
rm -rf /var/lib/dkms/aorus-laptop
rm -f /etc/modules-load.d/aorus-laptop.conf

echo "== Removing any previous registration =="
# Includes the "@PKGVER@" version left behind by `dkms ldtarball` on a tarball
# whose dkms.conf was not substituted.
# Capture the query WITH its exit status. A process substitution discards it, so
# a failing `dkms status` used to yield an empty list, run the loop zero times,
# and fall straight through to the `rm -rf` below -- deleting the tree while
# leaving the installed module and its source unmanaged. An absent module is not
# that case: `dkms status` exits 0 and prints nothing for a name it does not
# know, so a first install still passes here.
if ! registered=$(dkms status "$NAME"); then
	echo "\`dkms status $NAME\` failed, so its registration cannot be read." >&2
	echo "Refusing to delete /var/lib/dkms/$NAME blind. Inspect DKMS first." >&2
	exit 1
fi
while read -r ver; do
	[ -n "$ver" ] || continue
	echo "   removing $NAME/$ver"
	remove_dkms_version "$NAME" "$ver"
done < <(printf '%s\n' "$registered" | sed -n "s|^$NAME/\([^,:]*\).*|\1|p" | sort -u)
rm -rf "/var/lib/dkms/$NAME"

echo "== Installing source to $SRC =="
install -d "$SRC"
install -m 644 Makefile gigabyte-laptop.c "$SRC/"
sed "s/@PKGVER@/$VERSION/" dkms.conf > "$SRC/dkms.conf"

echo "== Building and installing =="
# `dkms add` returns non-zero when the version is already registered, which is
# not a failure worth aborting on. Under `set -e` it would skip everything
# below, including the reload, and leave the old module running while reporting
# success.
dkms add "$NAME/$VERSION" || true
if ! dkms install "$NAME/$VERSION" --force; then
	echo "dkms install failed" >&2
	# Close the residual window the pre-flight build cannot. That build catches
	# a compile error before anything is removed, which is the common cause --
	# but an install can still fail afterwards for a reason the pre-flight
	# cannot see: module signing, a full disk, a DKMS environment difference.
	# By then the previous registration and module are gone, and on a RE-RUN an
	# /etc/modules-load.d entry from the earlier run is still present, so the
	# next boot asks systemd-modules-load for a module that no longer exists
	# and fails with nothing explaining why.
	#
	# SAY SO; DO NOT DELETE IT. An earlier version of this failure path removed
	# the entry, and that broke an invariant documented at the top of this
	# script: the modules-load.d file is deliberately NOT ownership-gated
	# *because* the script only ever overwrites it with identical content, never
	# deletes it, except under an explicit --no-autoload. An install failure is
	# not an explicit request, so deleting it there would strand a packaged
	# gigabyte-laptop-dkms -- rpm or dpkg still listing a file that is gone,
	# which is the exact harm the ownership check exists to prevent.
	#
	# The two costs are not comparable. Leaving the entry costs one journal line
	# at the next boot ("Failed to find module 'gigabyte_laptop'"), which is
	# noise. Deleting a package-owned file damages the package database and
	# silently discards an autoload choice the caller never asked to drop.
	if [ -e /etc/modules-load.d/gigabyte-laptop.conf ]; then
		echo >&2
		echo "NOTE: /etc/modules-load.d/gigabyte-laptop.conf is still present, so" >&2
		echo "      the next boot will log 'Failed to find module gigabyte_laptop'" >&2
		echo "      until an install succeeds. That is cosmetic. To silence it" >&2
		echo "      yourself:" >&2
		echo "        sudo rm /etc/modules-load.d/gigabyte-laptop.conf" >&2
		echo "      It is left in place rather than removed here because a" >&2
		echo "      distro package may own it." >&2
	fi
	echo >&2
	echo "No driver is installed now. Fix the cause and run this again; the" >&2
	echo "autoload entry is written back by a successful install." >&2
	exit 1
fi

if [ "$AUTOLOAD" -eq 1 ]; then
	echo "== Enabling autoload at boot =="
	install -m 644 gigabyte-laptop.conf /etc/modules-load.d/gigabyte-laptop.conf
else
	# Drop any entry a previous run left, or --no-autoload would be a no-op
	rm -f /etc/modules-load.d/gigabyte-laptop.conf
	echo "== Autoload disabled (--no-autoload) =="
fi

echo "== Loading =="
# If the old module is in use the removal fails, and modprobe below would then
# be a no-op on the already-loaded copy. Say so rather than imply the new build
# is live.
if ! module_unload gigabyte_laptop; then
	echo "WARNING: could not unload the running gigabyte_laptop." >&2
	echo "         The previously loaded module stays active until you" >&2
	echo "         unload it manually or reboot. The new build is installed" >&2
	echo "         but NOT running." >&2
fi
modprobe gigabyte-laptop || echo "WARNING: modprobe gigabyte-laptop failed" >&2

echo
dkms status "$NAME"

signer=$(modinfo -F signer gigabyte-laptop 2>/dev/null) || signer=
installed=$(modinfo -F srcversion gigabyte-laptop 2>/dev/null) || installed=
loaded=$(cat /sys/module/gigabyte_laptop/srcversion 2>/dev/null) || loaded=

echo "signature: ${signer:-UNSIGNED}"
echo "installed: ${installed:-none}"
echo "loaded:    ${loaded:-not loaded}"
echo "nodes:     /sys/devices/platform/gigabyte_laptop"
echo

# Say plainly whether the code just built is the code now running. Getting this
# wrong silently costs a debugging session chasing symptoms of an old build.
if ! module_loaded gigabyte_laptop; then
	echo "WARNING: the module is installed but not loaded." >&2
	echo "         Load it with: modprobe gigabyte-laptop" >&2
	exit 1
elif [ -z "$installed" ] || [ -z "$loaded" ]; then
	# srcversion is normally present for both, but do not call a loaded module
	# stale just because the attribute could not be read.
	echo "The module is loaded. Could not compare source versions to confirm"
	echo "it is the build just installed."
elif [ "$installed" = "$loaded" ]; then
	echo "The running module is the one just installed."
else
	echo "WARNING: the running module is NOT the one just installed." >&2
	echo "         Reload it with:" >&2
	echo "           modprobe -r gigabyte_laptop && modprobe gigabyte-laptop" >&2
	if [ "$AUTOLOAD" -eq 1 ]; then
		echo "         or reboot, since autoload is enabled." >&2
	else
		echo "         Rebooting will NOT pick it up: autoload is disabled," >&2
		echo "         so nothing loads the module at boot." >&2
	fi
	exit 1
fi
