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
# Usage: sudo bash scripts/install-dkms.sh [--autoload]
set -euo pipefail

VERSION=0.2.0
NAME=aorus-laptop
SRC=/usr/src/$NAME-$VERSION
AUTOLOAD=0

for arg in "$@"; do
	case "$arg" in
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
	echo "== Autoload not enabled (pass --autoload to enable) =="
fi

echo "== Loading =="
modprobe -r aorus_laptop 2>/dev/null || true
modprobe aorus-laptop

echo
dkms status "$NAME"
echo "signature: $(modinfo -F signer aorus-laptop 2>/dev/null || echo 'UNSIGNED')"
echo "nodes:     /sys/devices/platform/aorus_laptop"
