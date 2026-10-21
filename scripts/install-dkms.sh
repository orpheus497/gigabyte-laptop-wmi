#!/bin/bash
# Install the aorus-laptop driver through DKMS.
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

NAME=aorus-laptop
# Take the version from the RPM spec, which is the project's canonical source,
# so DKMS registration cannot drift from packaging. Overridable, with the
# current value as a last resort if the spec is unreadable.
VERSION="${VERSION:-$(sed -n 's/^Version:[[:space:]]*//p' \
	"$(dirname "$0")/../pkg-files/rpm/aorus-laptop-dkms.spec" 2>/dev/null | head -1)}"
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

cd "$(dirname "$0")/.."

echo "== Removing any previous registration =="
# Includes the "@PKGVER@" version left behind by `dkms ldtarball` on a tarball
# whose dkms.conf was not substituted.
while read -r ver; do
	[ -n "$ver" ] || continue
	echo "   removing $NAME/$ver"
	dkms remove "$NAME/$ver" --all >/dev/null 2>&1 || true
	rm -rf "/var/lib/dkms/$NAME/$ver" "/usr/src/$NAME-$ver"
done < <(dkms status "$NAME" 2>/dev/null | sed -n "s|^$NAME/\([^,:]*\).*|\1|p" | sort -u)
rm -rf "/var/lib/dkms/$NAME"

echo "== Installing source to $SRC =="
install -d "$SRC"
install -m 644 Makefile aorus-laptop.c "$SRC/"
sed "s/@PKGVER@/$VERSION/" dkms.conf > "$SRC/dkms.conf"

echo "== Building and installing =="
dkms add "$NAME/$VERSION"
dkms install "$NAME/$VERSION" --force

if [ "$AUTOLOAD" -eq 1 ]; then
	echo "== Enabling autoload at boot =="
	install -m 644 aorus-laptop.conf /etc/modules-load.d/aorus-laptop.conf
else
	echo "== Autoload skipped (--no-autoload) =="
fi

echo "== Loading =="
# If the old module is in use the removal fails, and modprobe below would then
# be a no-op on the already-loaded copy. Say so rather than imply the new build
# is live.
if lsmod | grep -q '^aorus_laptop '; then
	if ! modprobe -r aorus_laptop; then
		echo "WARNING: could not unload the running aorus_laptop." >&2
		echo "         The previously loaded module stays active until you" >&2
		echo "         unload it manually or reboot. The new build is installed" >&2
		echo "         but NOT running." >&2
	fi
fi
modprobe aorus-laptop

echo
dkms status "$NAME"
signer=$(modinfo -F signer aorus-laptop 2>/dev/null) || signer=
echo "signature: ${signer:-UNSIGNED}"
echo "nodes:     /sys/devices/platform/aorus_laptop"
