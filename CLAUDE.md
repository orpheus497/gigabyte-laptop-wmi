# CLAUDE.md

Context for working on this repo. Read before touching `aorus-laptop.c`.

## What this is

A fork of [tangalbert919/gigabyte-laptop-wmi](https://github.com/tangalbert919/gigabyte-laptop-wmi),
an out-of-tree kernel driver that talks to the embedded controller on Gigabyte
Aero/AORUS/Gaming laptops through the `WMBC` and `WMBD` WMI methods. Controls are
exposed as sysfs nodes under `/sys/devices/platform/aorus_laptop`, sensors through
HWMON.

This checkout is being adapted for one specific machine (see below), with the
goal of fan/thermal control, power profiles, the GiMate button and RGB keyboard.

## Target hardware

Everything here is verified from the live machine, not assumed.

| | |
|---|---|
| Board / product | `GIGABYTE GAMING A16 5TH` |
| `DMI_PRODUCT_FAMILY` | `GIGABYTE GAMING` (exact match, gates driver support) |
| `DMI_PRODUCT_SKU` | `GA65TH` |
| BIOS | AMI `FB03`, `12/23/2025` → `dmi_get_bios_year()` = 2025 |
| EC firmware | 3.3 |
| CPU | AMD Ryzen 7 170, 8C/16T, `amd-pstate-epp` |
| GPU | NVIDIA RTX 5050 Laptop + amdgpu iGPU |
| OS | Fedora 44, kernel 7.2.11-200.fc44.x86_64 |
| Secure Boot | **enabled**, lockdown = `integrity` |

The upstream README cites `A16 GA6H` for Gaming (2025+) support, and the A16 fork
validated on `A16 CWH` / `GA6CWH`. This machine is the `5TH` gen, SKU `GA65TH` —
same family, different gen code, and AMD rather than Intel. **Treat fork-derived
method IDs as unvalidated here until checked via `debug_method`.**

### WMI devices (all present, all unclaimed)

```
ABBC0F6F-8EA1-11D1-00A0-C90629100000   WMBC   (read)     object_id BC
ABBC0F75-8EA1-11D1-00A0-C90629100000   WMBD   (write)    object_id BD
ABBC0F72-8EA1-11D1-00A0-C90629100000   event             notify_id D2
ABBC0F6C-8EA1-11D1-00A0-C90629100000                     object_id AC
```

### Derived driver state on this machine

`gaming_family = 1`, `fan_silent_method = FAN_SILENT_MODE`,
`dual_fan_speed_enabled = 1`, `has_dgpu_ejector = 1` (read-only node, ejection
blocked in code), `has_three_fans = has_four_fans = 0` → **2 fans, 3 temps,
2 PWM channels**.

### Hardware facts that invalidate common advice

- **No Super-I/O chip.** Fan tach lives behind the EC, reachable only via these
  WMI methods. CoolerControl's `Super-I/O probe blocked: SecureBoot` is a red
  herring; `nct6687` and similar desktop hwmon drivers are the wrong hardware.
- **The keyboard is PS/2** (`i8042`, `AT Translated Set 2 keyboard`). There is
  **no USB `0414:8105` keyboard** on this unit, so both published Gigabyte RGB
  tools ([Luminous418 LampArray](https://github.com/Luminous418/Gigabyte-Gaming-A16-Linux-KB-Drivers),
  [GigaMate pyusb](https://github.com/goodeesh/GigaMate)) cannot work here.
- **RGB/hotkey candidate channel:** `/sys/bus/hid/devices/0018:6243:0001.0003`
  → `/dev/hidraw2`, ACPI path `\_SB_.I2CB.ECSH`, vendor usage page `0xFF00`,
  report ID `0x0B`, symmetric 41-byte in/out, bound only to `hid-generic`.
  Protocol undocumented.
- **No `/sys/firmware/acpi/platform_profile`.** Nothing on this machine
  registers one.
- **`GBT0005:00`** is an unbound Gigabyte ACPI device (also present on machines
  as old as the Aero 15XV8). Windows loads a vendor driver for it. Purpose
  unknown; needs a DSDT dump to investigate. Neither bundled `.dsl` contains it.

## Repo layout and conventions

### Branches

| Branch | Purpose |
|---|---|
| `master` | Pristine upstream tracking. **Never commit here.** |
| `a16-5th` | Integration branch. All work lands here. |

Remotes: `origin` = upstream, `a16` = the A16 fork.

### Why the fork is ported, not merged

The fork branched at upstream `0002d21` and has 6 commits; `master` has ~60 the
fork lacks. `git diff --stat master a16/master` shows 771 changed lines in
`aorus-laptop.c`, most of it the fork *missing* master's work. Merging would
regress `fan_pwm`, hwmon PWM channels, `light_sensor`, `power_on_time`,
`has_dgpu_ejector`, the fan 3/4 quirks, the 0–255 `fan_custom_speed` range, and
the Debian/RPM packaging.

**Cherry-pick features from `a16/master`. Do not merge it.**

### Code style

Match the surrounding file: tabs, `pr_err`/`pr_info`/`pr_warn` with the
`KBUILD_MODNAME` prefix, `sysfs_emit` in show handlers, `kstrtouint` then
range-check then `gigabyte_laptop_set_devstate` in store handlers, block
comments above each node group documenting its value range. Comment density is
low — explain *why*, not *what*.

New method IDs for Gaming-only firmware go in the clearly labelled
`// Gigabyte Gaming (2025+) models only` block, not mixed into the
value-ordered lists.

## Build and install

```sh
make                                  # builds against /lib/modules/$(uname -r)/build
```

**`insmod` will fail on this machine.** Lockdown `integrity` enforces module
signatures even with `CONFIG_MODULE_SIG_FORCE=n`, and a freshly built `.ko` is
unsigned (`EKEYREJECTED`).

Install via DKMS, which signs automatically with the already-enrolled key:

```
/var/lib/dkms/mok.key          private key, intact
/var/lib/dkms/mok.pub          enrolled as "CN=DKMS module signing key"
```

- **Never remove the `dkms` package.** It is now a leaf package with nothing
  depending on it, so `dnf autoremove` will try to take it. Losing
  `/var/lib/dkms/mok.key` means re-enrolling a MOK key and a reboot into the
  MOK manager.
- Manual signing fallback: `/usr/src/kernels/$(uname -r)/scripts/sign-file`
  with the same key pair.

## Hazards

- **`FAN_DUTY_MAX` is `0xE5` (229), and that is a real ceiling.** Upstream issue
  #46: duties above 229 *stop the fans entirely* on the AERO 17-XA. The driver
  must never program a higher duty for itself. The `fan_custom_speed` node still
  accepts 0–255 as upstream intends.
- **Probe aborts the whole module on any optional-method failure.**
  `gigabyte_laptop_init()` treats a `gigabyte_laptop_probe()` error as fatal
  (`goto fail_probe`), and probe does `if (ret) return ret` after optional
  feature reads. One unsupported method ID kills the driver. Not yet fixed.
- **Unbounded `memcpy` in `gigabyte_laptop_get_devstate2()`.** The
  `ACPI_TYPE_BUFFER` branch copies `obj->buffer.length` bytes into a
  caller-supplied pointer with no clamp. Probe passes a 4-byte `u8[4]` for
  `LIGHT_SENSOR_NEW` (`0xFC`). This machine has no light sensor, so what that
  method returns here is unknown. Potential stack overflow. Not yet fixed.
- **`ec_read()` offsets are unverified on this EC.** `0xD` (auto-max fan mode
  detect) and `0x62` (board temp, `temp3_input`) were derived from Intel
  Aero/AORUS units. Cross-check `temp3_input` against `k10temp`.
- **`eeepc_wmi` steals our event GUID.** `/lib/modules/$(uname -r)/modules.alias`
  contains `alias wmi:ABBC0F72-8EA1-11D1-00A0-C90629100000 eeepc_wmi`. udev
  coldplugs the WMI event device, matches `eeepc_wmi`, which pulls in `asus_wmi`
  and logs `ASUS Management GUID not found`. ASUS's Eee PC interface and
  Gigabyte's AMW0 share the same AMI-derived GUID block. This must be
  blacklisted before working on the GiMate button.
- **Kernel cmdline carries leftovers from earlier fan-control attempts:**
  `acpi_osi=Linux acpi_enforce_resources=lax`. The latter relaxes ACPI resource
  conflict checks (needed for `ec_sys`-style direct EC poking, not for this
  driver). The former forces the firmware's Linux `_OSI` path and may be hiding
  vendor functionality gated on `_OSI("Windows ...")` — a live variable for the
  GiMate button.

## Phase status

### Phase 1 — housekeeping ✅ complete

Removed: `tuxedo-drivers`, `tuxedo-control-center`, `tccd*.service`, the orphan
`tuxedo-keyboard/3.2.10` DKMS tree, 28 unowned Clevo/Uniwill/ITE modules from
`/lib/modules/$(uname -r)/extra/`, `nct6687d`, `kmod-nct6687d`,
`/usr/lib/modules-load.d/nct6687.conf`, `/etc/modules-load.d/tuxedo`,
`tuxedo.repo`, the `fmonteghetti/keyd` COPR. Reinstalled `dkms`. Installed
`acpica-tools`. Rebooted.

The TUXEDO stack targets Clevo/Uniwill/TongFang barebones. The 2024-and-older
Gigabyte G5/G7 were rebadged Clevo; the 2025+ `GIGABYTE GAMING` family is
Gigabyte's own design, which is why it is in this driver's DMI table instead.

Kept: `codifryed/CoolerControl` COPR (the fan UI this driver feeds),
`ublue-os/akmods` (required by `akmod-nvidia`), `dkms`, `kernel-devel-matched`.

### Phase 2 — port the A16 fork ✅ complete

`bb2fd27` — ported `perf_mode` (`0xED`), `dynamic_boost` (`0xE7`),
`fan_turbo` (`0x7D`) plus `FAN_DUTY_MAX`.

- `is_visible` on the attribute group **re-enabled** (upstream had it commented
  out) to hide the three Gaming-only nodes elsewhere.
- `gaming_family` is set in `gigabyte_laptop_init()`, **not** `probe()`.
  `sysfs_create_group()` runs before `probe()`, so a flag set in probe reads as
  zero when `is_visible` is consulted and the nodes never appear.
- The EC takes `DYN_BOOST` inverted; the inversion is hidden in the driver so
  the node reads/writes 0=off / 1=on like everything else.
- `fan_turbo` rewritten. The fork reached full speed by calling its own sysfs
  store handlers from a workqueue, falling back to `call_usermodehelper()`
  running `/bin/sh -c "echo ... > /sys/..."`. Replaced with direct hardware
  writes: the duty write is factored out of `fan_custom_speed_store()` into
  `set_fan_custom_speed()`, shared by both paths. Restore order corrected —
  duty before mode, because `set_fan_mode(FAN_AUTO_MODE)` programs the fans
  from `fan_custom_speed`.
- `FAN_TURBO` (`0x7D`) is written only on *disable*, to clear the bit. The
  fork's history shows writing it on enable did not hold the fans on the CWH,
  hence the duty+fixed-mode latch. Deliberate asymmetry.

`4a96703` — fixed `gpu_boost_store()` dereferencing `gigabyte` before assigning
it from `dev_get_drvdata()`. Any write to the node oopsed the kernel. Upstream
issue #45.

Not ported: `scripts/install-dkms.sh` (hardcodes version 0.1.0; installs a
service pinning max TGP at every boot, including on battery),
`scripts/test-a16-cwh.sh` (reusable harness, but its `≥6000 RPM` assertion
needs re-baselining), the fork's `*.dsl` gitignore line (we want to commit this
machine's DSDT).

Both commits build clean with `-Wall -Wextra`.

### Phase 3 — remaining work

| Step | Work | Risk |
|---|---|---|
| 0 | DKMS install, load, verify hwmon channels appear | low |
| 1 | Clamp the `memcpy`; make optional probe reads non-fatal | low |
| 2 | Validate `0xED` / `0xE7` / `0x7D` on `GA65TH` via `debug_method` | medium |
| 3 | Register a real `platform_profile` handler | low |
| 4 | Writable `pwm1`/`pwm2` for CoolerControl | medium |
| 5 | GiMate button — diagnose, then notify handler + keymap | low |
| 6 | RGB over `/dev/hidraw2` (report `0x0B`, 41 bytes) | high |

Step 2 gates everything GPU-related. Step 6 is open-ended research; treat it as
a separate project rather than a blocker.

**GiMate diagnosis order** (stop `input-remapper` first — it clones the keyboard
into `input21`/`input22` and will confuse scancode capture):

1. i8042 scancode — `showkey --scancodes` / `evtest /dev/input/event1`. If it
   emits an unmapped scancode, `keyd` or a udev hwdb entry solves it with no
   kernel work.
2. WMI notify `0xD2` on `ABBC0F72` — `acpi_listen`. Strong prior: the bundled
   AORUS DSDT fires `Notify (AMW0, 0xD2)` from inside `WMBC`
   (`AORUS-17X-VF-DSDT.dsl:125336`). The driver defines `WMI_EVENT` and never
   uses it — no `wmi_install_notify_handler`, no input device, no
   `sparse_keymap`.
3. The `\_SB_.I2CB.ECSH` i2c-HID pipe.

## Open decisions

- **Step 3 interface shape** — whether `perf_mode` survives alongside a
  `platform_profile` handler, or is replaced by it.
- **`tuned` vs `power-profiles-daemon`** — currently `tuned` on
  `balanced-battery`, PPD inactive. Affects Step 3 wiring.
- **Upstreaming** — the probe fixes, the `gpu_boost` oops (#45) and the duty
  clamp (#46) are all plausibly acceptable upstream, which would reduce rebase
  burden.

## Settled decisions

- **No Windows dual-boot on this machine.** A Windows USB install is available
  as a later option if Step 6 needs GiMate traffic captured. Until then, RGB
  work means blind-probing report `0x0B`, where GigaMate's firmware-hang
  warning applies.
- CPU power management is out of scope. `amd-pstate-epp` with `dynamic_epp` and
  `prefcore` already works; this driver must not touch it. The gap is GPU TGP
  and fan policy.
