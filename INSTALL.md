# Installation

## How to install

For all methods, you must copy `gigabyte-laptop.conf` to `/etc/modules-load.d/` so the kernel module is loaded on boot automatically.

### Method 1: Using DKMS

**Note:** If you have Secure Boot enabled, you must follow [these instructions](https://github.com/dell/dkms?tab=readme-ov-file#secure-boot) or the module will not load.

This module can be installed using DKMS. You can download the driver tarball from the [releases page](https://github.com/tangalbert919/gigabyte-laptop-wmi/releases) and load it into the DKMS tree:
```
dkms ldtarball driver.tar.gz
```

If you have this repository checked out locally, the simplest route is the
install script, which handles the version substitution, removes any earlier
registration and installs the `/etc/modules-load.d` entry:
```
sudo bash scripts/install-dkms.sh          # or --no-autoload to skip boot loading
```

To build a tarball by hand instead:
```
tar -czf driver.tar.gz Makefile gigabyte-laptop.c dkms.conf gigabyte-laptop.conf
```

`dkms.conf` ships `PACKAGE_VERSION="@PKGVER@"` as a placeholder for the
packaging to substitute, so **replace it with the real version before creating
the tarball**. Loading the tarball as it stands registers a module literally
versioned `@PKGVER@`, and the `dkms install` that follows then fails with
"Could not find module source directory".

`gigabyte-laptop.conf` is the `/etc/modules-load.d` entry referred to above.
DKMS does not install it for you, so include it in the archive and copy it into
place by hand.

### Method 2: Manually

**Note:** If you have Secure Boot enabled, you must sign the kernel module after compiling it. Using a signing key already enrolled into the computer is recommended.

Simply run the following commands:
```
make
sudo insmod gigabyte-laptop.ko
```

The last command has to be run after every reboot. If you have updated the kernel, you must run `make` before loading the kernel module.

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
