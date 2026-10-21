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
| APU silicon | **Rembrandt** (Zen 3+). Host bridge `1022:14b5` = `AMD_CPU_ID_RMB`, `Rembrandt Data Fabric`, `Rembrandt [Radeon 680M]` `1002:1681`. "Ryzen 7 170" is rebranded Rembrandt, not new silicon. |
| GPU | NVIDIA `GB207M [RTX 5050 Max-Q / Mobile]` `10de:2d98` + amdgpu iGPU |
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
- **No platform profile is registered.** `/sys/class/platform-profile/` exists
  but is **empty**, and `/sys/firmware/acpi/platform_profile` does not exist.
  The slot is free — see "Power profiles" below.
- **`GBT0005:00`** is an unbound Gigabyte ACPI device (also present on machines
  as old as the Aero 15XV8). Windows loads a vendor driver for it. Purpose
  unknown; needs a DSDT dump to investigate. Neither bundled `.dsl` contains it.

## Power profiles

### This kernel uses the new multi-handler class API

`include/linux/platform_profile.h` on 7.2 matches current master exactly.
`probe`, `profile_get` and `profile_set` are **mandatory** (the core does
`WARN_ON_ONCE` and returns `-EINVAL` otherwise); `hidden_choices` is optional;
`probe` must set **at least one** bit or registration fails with "Failed to
register platform_profile class device with empty choices".

```c
struct platform_profile_ops {
	int (*probe)(void *drvdata, unsigned long *choices);
	int (*hidden_choices)(void *drvdata, unsigned long *choices);
	int (*profile_get)(struct device *dev, enum platform_profile_option *profile);
	int (*profile_set)(struct device *dev, enum platform_profile_option profile);
};
struct device *devm_platform_profile_register(struct device *dev, const char *name,
					      void *drvdata,
					      const struct platform_profile_ops *ops);
int platform_profile_cycle(void);
void platform_profile_notify(struct device *dev);
```

Eight slots: `low-power`, `cool`, `quiet`, `balanced`, `balanced-performance`,
`performance`, `max-power`, `custom`.

Registering creates `/sys/class/platform-profile/platform-profile-N/{name,choices,profile}`
**and** the legacy aggregate `/sys/firmware/acpi/platform_profile`, which
`drivers/acpi/platform_profile.c` maintains as the intersection of all
handlers' choices, reading `custom` when handlers disagree.

Closest reference implementation is `drivers/platform/x86/dell/dell-pc.c`: it
passes `NULL` drvdata, omits `hidden_choices`, and its `probe` resyncs hardware
to the firmware's current mode. `amd/pmf/sps.c` is the model for
`hidden_choices`.

`platform_profile_cycle()` is what `asus-wmi` calls from its hotkey handler, so
**Step 3 and Step 5 share an implementation**. Caveats from the core: it
advances every registered handler in lockstep, returns `-EINVAL` when the
aggregate reads `custom`, stops at the first failing `profile_set` leaving
earlier handlers changed, and notifies by itself. Use
`platform_profile_notify()` only when the EC changes mode on its own.

### tuned already drives this — keep tuned, do not install PPD

Fedora 44's `tuned` ships `plugins/plugin_acpi.py`, and it writes the **legacy**
path, not the class path. `tuned/ppd/controller.py` hardcodes
`PLATFORM_PROFILE_PATH = "/sys/firmware/acpi/platform_profile"` and monitors it.
The active profile already requests it:

```ini
balanced                → platform_profile=balanced
powersave               → platform_profile=low-power|quiet
throughput-performance  → platform_profile=performance
latency-performance     → platform_profile=performance
```

So the minimum set the handler must expose is `low-power` (or `quiet`),
`balanced`, `performance` — a 1:1 fit with `perf_mode` 0/1/2. The moment the
driver registers, the existing `tuned` setup starts switching GPU TGP with no
further configuration. `tuned` also contains a power-profiles-daemon D-Bus
shim, so GNOME/KDE's power menu works through it; `power-profiles-daemon`
itself is **not** wanted.

### amd_pmf is one kernel parameter away from binding

`amd_pmf` is loaded but unbound. The platform device
`/sys/devices/platform/AMDI0100:00` exists with no `driver` link, so
`amd_pmf_probe()` ran and returned `-ENODEV`. Exactly one gate fails:

```c
// drivers/platform/x86/amd/pmf/core.c
{"AMDI0100", 0x100},   // this machine
if (id->driver_data == 0x100 && !force_load)
	return -ENODEV;
```

The host bridge gate passes (`1022:14b5` is `AMD_CPU_ID_RMB`, in
`pmf_pci_ids`), and `force_load` reads `N`. AMD gates `AMDI0100` behind
`force_load` and documents it as "Force load this driver on supported older
platforms (experimental)" — consistent with this being Rembrandt.

If it binds, `amd_pmf_init_sps()` registers a **second** handler named
`amd-pmf` with `low-power`/`balanced`/`performance` visible and
`quiet`/`balanced-performance` hidden, governing APU/SMU power while ours
governs GPU TGP and fans. Consequences to design around: the legacy aggregate
becomes the intersection, disagreement surfaces as `custom`, a legacy write
goes to *every* handler and fails if any returns `-EOPNOTSUPP`, and
`platform_profile_cycle()` starts returning `-EINVAL` whenever the two
disagree. Whether the Gigabyte BIOS exposes
`APMF_FUNC_STATIC_SLIDER_GRANULAR` is unknown without the DSDT.

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
| 3 | Register a `platform_profile` handler over `perf_mode` + `dynamic_boost` | low |
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

- **Upstreaming** — the probe fixes, the `gpu_boost` oops (#45) and the duty
  clamp (#46) are all plausibly acceptable upstream, which would reduce rebase
  burden.

## Settled decisions

### Step 3 design

- **A profile switch sets `perf_mode` and `dynamic_boost` only.** Fan settings
  are deliberately left alone, so a custom fan curve survives profile changes.
  Target mapping:

  | Profile | `perf_mode` | `dynamic_boost` |
  |---|---|---|
  | `quiet` | 0 eco | off |
  | `low-power` | 0 eco | off |
  | `balanced` | 1 | off |
  | `balanced-performance` | 1 | on |
  | `performance` | 2 boost | on |

- **Keep the raw `perf_mode` node alongside `platform_profile`.**
  `platform_profile` is the canonical writer; `perf_mode` reads through the
  same stored value and stays available for scripting and for debugging a bad
  mapping. One source of truth in the driver, two views onto it — they must not
  be able to disagree.
- **Test `amd_pmf.force_load=1` before writing Step 3**, so it is known whether
  the handler will be sharing the aggregate with `amd-pmf`.
  `sudo grubby --update-kernel=ALL --args="amd_pmf.force_load=1"`, reboot, then
  read `/sys/class/platform-profile/*/{name,profile,choices}`. Revert with
  `grubby --remove-args`.
- **Keep `tuned`; do not install `power-profiles-daemon`.**

### Step 2 validation

Read `0xED`, `0xE7` and `0x7D` through `debug_method` and confirm sane values
**before any write**. Then enable `fan_turbo` for roughly 3 seconds on AC while
idle, watching `fan1_input`/`fan2_input`, and confirm the fans resume on
disable. The short burst is deliberate: this is the path that touches the duty
ceiling which stopped fans on the AERO 17-XA (upstream #46).

### Other

- **No Windows dual-boot on this machine.** A Windows USB install is available
  as a later option if Step 6 needs GiMate traffic captured. Until then, RGB
  work means blind-probing report `0x0B`, where GigaMate's firmware-hang
  warning applies.
- CPU power management is out of scope. `amd-pstate-epp` with `dynamic_epp` and
  `prefcore` already works; this driver must not touch it. The gap is GPU TGP
  and fan policy.

## Pending root-only diagnostics

Neither can run from a non-interactive shell; they need a password.

```sh
# DSDT dump — identifies GBT0005, shows whether APMF methods exist,
# and shows what \_SB_.I2CB.ECSH is wired to
sudo acpidump -b && iasl -d dsdt.dat

# Live capture on the ECSH vendor pipe. Press GiMate / Fn+Space / Mode
# while this runs. Read-only; it only listens.
sudo timeout 20 cat /dev/hidraw2 | xxd
```

If bytes appear on `hidraw2` when GiMate is pressed, Steps 5 and 6 both open up
considerably.
