# Installation

## How to install

The module registers its platform device by hand and exposes no modalias, so
udev has nothing to match and **nothing loads it at boot on its own**. If you
want it loaded automatically, copy `gigabyte-laptop.conf` to
`/etc/modules-load.d/`. That is a choice, not a requirement — skip it and load
the module by hand instead.

### Method 1: Using DKMS

**Note:** If you have Secure Boot enabled, you must follow [these instructions](https://github.com/dell/dkms?tab=readme-ov-file#secure-boot) or the module will not load.

This module can be installed using DKMS. You can download the driver tarball from the [releases page](https://github.com/tangalbert919/gigabyte-laptop-wmi/releases) and load it into the DKMS tree:
```
dkms ldtarball driver.tar.gz
dkms install gigabyte-laptop/<version>
```

`dkms ldtarball` unpacks into the DKMS tree, not the current directory, so the
`/etc/modules-load.d` entry has to come out of the archive or the installed
source. Either of these, if you want loading at boot:
```
tar -xzf driver.tar.gz gigabyte-laptop.conf
sudo install -m 644 gigabyte-laptop.conf /etc/modules-load.d/
# or, once dkms install has run:
sudo install -m 644 /usr/src/gigabyte-laptop-<version>/gigabyte-laptop.conf /etc/modules-load.d/
```

If you have this repository checked out locally, the simplest route is the
install script, which handles the version substitution, removes any earlier
registration and installs the `/etc/modules-load.d` entry:
```
sudo bash scripts/install-dkms.sh          # or --no-autoload to skip boot loading
```

To build a tarball by hand instead. **The substitution has to happen before
`tar` runs**, so stage the files rather than archiving the checkout directly:
```
VER=0.2.0
d=$(mktemp -d)
cp Makefile gigabyte-laptop.c gigabyte-laptop.conf "$d/"
sed "s/@PKGVER@/$VER/" dkms.conf > "$d/dkms.conf"
tar -czf driver.tar.gz -C "$d" .
rm -rf "$d"
```

`dkms.conf` ships `PACKAGE_VERSION="@PKGVER@"` as a placeholder for the
packaging to substitute. Archiving it unsubstituted registers a module
literally versioned `@PKGVER@`, and the `dkms install` that follows then fails
with "Could not find module source directory". Staging into a temporary
directory also keeps `sed` off the tracked `dkms.conf`.

`gigabyte-laptop.conf` is the `/etc/modules-load.d` entry referred to above.
DKMS does not install it for you, so include it in the archive and copy it into
place by hand if you want boot loading. `scripts/install-dkms.sh` does it for
you unless you pass `--no-autoload`.

### Upgrading from the old `aorus-laptop` name

The driver was renamed, and **the RPM packaging handles the whole old set** —
`gigabyte-laptop-kmod-common` and `gigabyte-laptop-dkms` obsolete their
predecessors directly, and the generated kmod and akmod subpackages do too, via
`kmodtool --obsolete-name`. So an ordinary upgrade replaces
`akmod-aorus-laptop`, `kmod-aorus-laptop` and `aorus-laptop-kmod-common`
without intervention.

If you have a mixed state from before that was in place, the removal is:
```
sudo dnf remove akmod-aorus-laptop aorus-laptop-kmod-common
```

`scripts/install-dkms.sh` handles the DKMS side of the rename itself, and it
will stop rather than delete files a package still owns, naming the package to
remove.

### Method 2: Manually

**Note:** If you have Secure Boot enabled, you must sign the kernel module after compiling it. Using a signing key already enrolled into the computer is recommended.

Simply run the following commands:
```
make
sudo modprobe -a wmi sparse-keymap
sudo insmod gigabyte-laptop.ko
```

`insmod` resolves no dependencies. `modinfo -F depends gigabyte-laptop.ko`
reports `wmi,sparse-keymap`, and without both the load fails with unknown
symbols — `wmi` for the WMI bus, `sparse-keymap` for the hotkey input device.
`modprobe` would handle that itself, but it only finds modules already installed
under `/lib/modules`, which is what the DKMS method above does.

The last two commands have to be run after every reboot. If you have updated the kernel, you must run `make` before loading the kernel module.

## How to remove

If you have installed the kernel driver with DKMS, you can run this command to remove it from the DKMS tree:
```
# Replace <version> with the version of the driver in use. Use "dkms status" if you are not sure what version you have installed.
sudo dkms remove gigabyte-laptop/<version> --all
```

If you have installed the kernel driver manually, you can simply run this command:
```
sudo rmmod gigabyte_laptop
```
