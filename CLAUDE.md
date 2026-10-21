# CLAUDE.md

Context for working on this repo. Read before touching `gigabyte-laptop.c`.

## What this is

A fork of [tangalbert919/gigabyte-laptop-wmi](https://github.com/tangalbert919/gigabyte-laptop-wmi),
an out-of-tree kernel driver that talks to the embedded controller on Gigabyte
Aero/AORUS/Gaming laptops through the `WMBC` and `WMBD` WMI methods. Controls are
exposed as sysfs nodes under `/sys/devices/platform/gigabyte_laptop`, sensors through
HWMON.

This checkout is being adapted for one specific machine (see below), with the
goal of fan/thermal control, power profiles, the GiMate button and RGB keyboard.

## Target hardware

Everything here is verified from the live machine, not assumed.

| | |
|---|---|
| Model line | **A16 5-series (5VH / 5TH)** — *not* the 3VH/3WH line |
| Board / product | `GIGABYTE GAMING A16 5TH` |
| `DMI_PRODUCT_FAMILY` | `GIGABYTE GAMING` (exact match, gates driver support) |
| `DMI_PRODUCT_SKU` | `GA65TH` |
| `DMI_PRODUCT_VERSION` | `-CF` |
| BIOS | AMI `FB03`, `12/23/2025` → `dmi_get_bios_year()` = 2025 |
| EC firmware | 3.3 |
| CPU | AMD Ryzen 7 170, 8C/16T, `amd-pstate-epp` |
| APU silicon | **Rembrandt** (Zen 3+). Host bridge `1022:14b5` = `AMD_CPU_ID_RMB`, `Rembrandt Data Fabric`, `Rembrandt [Radeon 680M]` `1002:1681`. "Ryzen 7 170" is rebranded Rembrandt, not new silicon. |
| GPU | NVIDIA `GB207M [RTX 5050 Max-Q / Mobile]` `10de:2d98` + amdgpu iGPU |
| OS | Fedora 44, kernel 7.2.11-200.fc44.x86_64 |
| Secure Boot | **enabled**, lockdown = `integrity` |

### Model line — read this before applying anything found online

This is an **A16 5-series** machine. Separate two kinds of external finding:

- **Hardware-specific numbers do not transfer.** TGP and power figures, fan RPM
  targets, GPU tier, and anything on an Intel-only code path belong to the unit
  that produced them.
- **DSDT method analysis does transfer, as a starting point.** The AML is
  near-identical across this firmware generation, so `GAMING-A16-3VH-DSDT.dsl`
  in this repo **is** the accepted reference for WMI method bodies and EC field
  names — pending `debug_method` validation on `GA65TH`.

Gigabyte's A16 gen codes follow `GA6` + a two-or-three character suffix, and the
suffix tracks the generation and GPU tier, so reports from other suffixes are
not transferable without checking:

| Source | Gen | Relationship to this machine |
|---|---|---|
| This machine | `5TH` / `GA65TH` | the target |
| Same model line | `5VH` | sibling variant, treat as closest reference |
| A16 fork (JoseLopez36) | `CWH` / `GA6CWH`, RTX 5070, Intel | **different gen, different vendor CPU** |
| Upstream README | `GA6H` | generic Gaming (2025+) reference |
| GigaMate experimental list | `CMH`, `CVH`, `CTH`, `CWH` | other gens, unverified here |
| Luminous418 RGB repo | `CTH` | different gen, and USB keyboard this unit lacks |
| A16 3-series | `3VH`, `3WH`, `3TH` | different line; **firmware analysis reusable**, hardware numbers not |

Two consequences:

- **DMI matching is safe across gens.** The driver's match table keys on
  `DMI_BOARD_VENDOR` + `DMI_PRODUCT_FAMILY` (`GIGABYTE GAMING`), never on the
  gen suffix, so the gate passes regardless.
- **Method IDs are not safe across gens.** `0xED`, `0xE7` and `0x7D` were
  validated on `CWH` — a different generation on Intel, where this is AMD
  Rembrandt. **Treat every fork-derived method ID as unvalidated until checked
  on this unit via `debug_method`.** Same for the fork's `~6500 RPM` turbo
  figure and its 55 W → 70 W TGP numbers, which are RTX 5070 values; this unit
  has an RTX 5050.

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
- **The RGB/hotkey channel is an ENE Technology embedded controller.**
  `/sys/bus/hid/devices/0018:6243:0001.0003` → `/dev/hidraw2`, ACPI path
  `\_SB_.I2CB.ECSH`, vendor usage page `0xFF00`, report ID `0x0B`, symmetric
  41-byte in/out, bound only to `hid-generic`. Identified from firmware: the
  AMD DSDT declares `_HID "1025174B"` with `_CID "PNP0C50"` (HID-over-I2C) at
  I²C address `0x05` on `\_SB.I2CB`, and the Intel CWH declares the *same*
  device as `_HID "ENES6243"`. ENE Technology is Taiwan stock code 6243, which
  is also the HID vendor ID `0x6243`. So this is an ENE EC exposed as i2c-HID.
  The report protocol is still undocumented — nobody has driven RGB on a
  non-USB Gigabyte keyboard.
- **No platform profile is registered.** `/sys/class/platform-profile/` exists
  but is **empty**, and `/sys/firmware/acpi/platform_profile` does not exist.
  The slot is free — see "Power profiles" below.
- **`GBT0005:00` is a live notify target on this machine — a Step 5 candidate.**
  Earlier notes said it was an inert side-effect stub; that was the 3VH, and it
  is **wrong for the 5TH**. On BIOS FB03 it is simply present, with no dGPU
  latch and no `RXCM` check:

  ```asl
  Device (GAPD) {
      Name (_HID, EisaId ("GBT0005"))
      Method (_STA, 0, NotSerialized) { Return (0x0F) }
  }
  ```

  and the EC fires events at it:

  ```asl
  Method (_Q63, 0, NotSerialized) { Notify (GAPD, 0xCF) }
  ```

  That is the behaviour previously thought Intel-only, and it is what the
  Windows UMDF driver on `ACPI\GBT0005` listens for. Since the GiMate key emits
  **no i8042 scancode at all** (tested), this is now a leading candidate for it,
  and an `acpi_driver` with a notify handler is simpler than the WMI route.

## Firmware reference

**`GAMING-A16-5TH-DSDT.dsl` is this machine's own firmware** — dumped from BIOS
FB03 with `acpidump -b` and decompiled with `iasl -d`. Use it in preference to
everything else. `GAMING-A16-5TH-SSDT12-APMF.dsl` is the SSDT holding `AMDI0100`
and the APMF interface.

`GAMING-A16-3VH-DSDT.dsl` is the public 3VH DSDT that was used before the real
dump existed. It turned out to be an excellent reference: **the WMBD and WMBC
top-level case lists are identical between the two**, and `ECSH` is declared the
same way down to `_HRV 0x8001`. Kept for cross-generation comparison.

Where they differ, the 5TH is authoritative, and the differences found so far
are recorded below — `GBT0005` in particular behaves nothing like the 3VH.

`acpidump -b` writes into the **current directory**, so `cd` somewhere scratch
first. A dump drops ~43 `.dat` files and `iasl -d dsdt.dat ssdt*.dat` produces a
matching set of `.dsl`. `*.dat` is gitignored; `*.dsl` deliberately is not, so
firmware kept as reference gets committed on purpose rather than by accident.

### Method IDs present in the AMD sibling

Verified by reading the `Switch` case lists directly:

```
WMBD (write): 46 47 50 51 57 61 63 64 65 66 67 68 6A 6B 70 71 7D 80 87 88
              A1 A3 C4 C7 C9 CA CB D9 E6 E7 ED F6 FA
WMBC (read):  03 46 47 50 57 61 63 64 65 67 68 6A 6B 6F 70 71 7D 80 87 88
              A1 A2 A3 C4 C7 C9 CA D9 E1 E2 E3 E4 E5 E6 E7 EB EF F6
```

Count only the cases at the switch's own indent level. Both methods contain
nested switches — `0xED`'s body has its own `Case (0x02)`/`Case (0x03)` setting
`NPCF.ATPP` — and a naive range grep picks those up as if they were method IDs.
`WMBD` has no `0x02` or `0x03`; `0x03` is WMBC-only and is the synthetic event
trigger described below. `WMBD` also has no `If (Arg1 == ...)` prelude, going
straight to `Switch (Arg1)`.

All three ported IDs are present on **AMD** firmware, which is the main thing
Phase 2 needed: `0xED`, `0xE7`, `0x7D`.

### WMBC echoes unknown method IDs — this breaks naive validation

Both methods end with a catch-all:

```asl
Default { Return (Arg2) }
```

and `wmi_evaluate_method()` passes `Arg2` as a 4-byte **buffer**, so an
unimplemented ID comes back through `get_devstate2()`'s buffer branch as the
argument that was sent. Two consequences:

- **A read of an unsupported ID looks like success and returns your argument.**
  `debug_method` always sends `0`, so every unimplemented ID reads as `0` —
  indistinguishable from a real value of `0`. `debug_method` must be extended to
  take an argument, and validation must use a **sentinel**: read with `0x5A`,
  and if `0x5A` comes back the ID is not implemented. **Step 2 is not
  trustworthy until that is done.**
- **It is also why the module loaded before Step 1 hardened the probe.** `0xFC`
  (`LIGHT_SENSOR_NEW`) is absent from AMD firmware, and the probe then did
  `if (ret) return ret` after that read, with init treating probe failure as
  fatal. The Default rescued it: the read "succeeded" with zeroes,
  `light_sensor_result[0] != 0xF7`, and probe carried on to the old
  light-sensor path — equally absent, equally harmless. Confirmed on hardware:
  the load logs `Using old light sensor method` and no light-sensor warning.
  The unbounded `memcpy` was not reachable either, because the echoed buffer is
  only 4 bytes. Both are fixed regardless; see Hazards.

Every other WMI read the probe performs *is* implemented in AMD WMBC: `0x57`,
`0x71`, `0x67`, `0x6A`, `0x6B`, `0x64`, `0x65`, `0x68`, plus `0xE7`. The only
non-WMI risk in probe is `ec_read(0xD)`, reached only when the machine is
already in custom fan mode at load time.

### Firing the event synthetically

`WMBC` short-circuits before its switch:

```asl
Method (WMBC, 3, Serialized) {
    If ((Arg1 == 0x03)) { Notify (AMW0, 0xD2) ; Return (Arg1) }
    Else { Switch (Arg1) { ... } }
}
```

So **method ID `0x03` fires the WMI event on demand**. Once a notify handler
exists, reading `0x03` is a self-test for the whole event path that needs no
hotkey press. Note the corollary for Step 5: a notify with no registered
handler is dropped by `wmi.ko`, so `acpi_listen` will likely show nothing
today — testing the event path properly requires the handler first.

Asymmetries that matter:

| ID | Node | Firmware behaviour |
|---|---|---|
| `0xED` | `perf_mode` | **WMBD only — write-only.** No WMBC case, so the mode in effect cannot be read back. |
| `0xE7` | `dynamic_boost` | WMBD writes, WMBC returns `NPCF.DBAC`. Writing `0` sets `DBAC = 1`, so **DBAC is already in the node's sense** — invert on write only, never on read. |
| `0x7D` | `fan_turbo` | WMBD writes and WMBC reads `EC0.TFAN`. Confirms `0x7D` is a plain EC bit, consistent with it not holding the fans on its own. |
| `0x51` | `gpu_boost` | **WMBD only — write-only.** `gpu_boost` reports the last written value, 0 after a cold boot. |
| `0x6D`/`0x6E` | `battery_cycle` | Absent from both. Reads return the echoed argument, i.e. `0`, not an error. |

One caveat on `dynamic_boost` that the firmware cannot settle: the ASL proves
the node **round-trips** (`write 0` → `DBAC = 1` → reads back `1`), but not
which direction means "boost on". That rests on the fork's testing on a CWH.
Confirm against `nvidia-smi` in Step 2; if it is backwards, the node is
self-consistent but semantically inverted.

Because `perf_mode` is write-only, the `platform_profile` handler's `probe`
must **write** a known profile to make its cached value truthful — the same
thing `dell-pc.c` does with `thermal_set_mode()` in its probe.

### Method IDs we are not using yet

Worth knowing these exist on AMD firmware, all verified in both directions
unless noted:

| ID | EC field | What it is |
|---|---|---|
| `0xF6` | `EC0.KBLL` (8-bit) | **Keyboard backlight brightness**, read *and* write |
| `0xD9` | `EC0.KBAT` (1-bit) | Keyboard backlight auto/timeout |
| `0xC9` | — | Fn-lock |
| `0xC7` | `EC0.MUTE` | Mute status |
| `0x87` / `0x88` | — | Power LED / battery LED |
| `0xE6` | — | dGPU mux (0 dynamic, 1 discrete, 2 MS-Hybrid) |
| `0x63` | `WXCM 0xD2`–`0xD6` | Five bytes in, five back. RGB-shaped, see Step 6 |
| `0x03` | — | Fires the WMI event synthetically: `WMBC(0, 0x03, n)` → `Notify (AMW0, 0xD2)` |

`0xF6` is the significant one: **keyboard backlight brightness is reachable
over WMI on AMD A16 firmware**, independent of the ENE colour protocol. Nowng's
AERO X16 fork already implements it as a `keyboard_brightness` node.

### The 0xD2 event chain, decoded

All three sibling DSDTs implement the same path, which answers what the event
carries:

```
EC query _Q45 → SMGR(WEVN, WEVS)
SMGR(a,b)     → DEVS[0]=a, DEVS[1]=b ; AMW0.WMBC(0, 0x03, a)
WMBC(_,0x03,_)→ Notify (AMW0, 0xD2)
_WED(0xD2)    → returns DEVS, a 4-byte buffer {WEVN, WEVS, 0xBB, 0xCC}
```

So byte 0 is the EC's event number and byte 1 its state. `WEVS`/`WEVN` are EC
fields at offsets `0x01`/`0x02` of the `PECM` region, at `0xFC7E0800` on AMD.

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
disagree.

**The firmware does implement APMF**, in `GAMING-A16-5TH-SSDT12-APMF.dsl`
(`ssdt12` in a fresh dump). `Device (PMF)` carries `_HID "AMDI0100"` and
`Method (APMF, 2, Serialized)` dispatches functions **`0x00` through `0x0E`** —
a complete implementation, with dedicated memory areas named for functions 9,
B, C and D (`PF9A`, `PFBA`, `PFCA`, `PFDA`).

Whether `APMF_FUNC_STATIC_SLIDER_GRANULAR` is *advertised* still cannot be read
statically. Function 0 returns `M159 = M481`, the supported-function bitmask,
and `M481` is a 32-bit field in `OperationRegion (PMT0, SystemMemory,
0xB807BC8C, 0x0D)` — runtime BIOS data, not an ASL constant, and `/dev/mem` is
closed under lockdown. So `amd_pmf.force_load=1` is the way to settle it, and it
is now a well-motivated test rather than a guess: a BIOS that ships ASL for all
fifteen APMF functions is unlikely to advertise none of them.

## Repo layout and conventions

### The driver is `gigabyte-laptop`, renamed from `aorus-laptop`

Upstream still calls the file `aorus-laptop.c` for historical reasons — it began
as an Aero/AORUS driver and gained `GIGABYTE GAMING` and P-series support later
without the name following. Every internal symbol was already
`gigabyte_laptop_*`, and the constant feeding the user-visible names was already
called `GIGABYTE_LAPTOP_FILE`, so the filename was the only thing out of step.

Because that constant is `KBUILD_MODNAME`, which comes from the filename, the
rename moved everything at once:

| | Before | After |
|---|---|---|
| Source | `aorus-laptop.c` | `gigabyte-laptop.c` |
| Module | `aorus_laptop` | `gigabyte_laptop` |
| sysfs | `/sys/devices/platform/aorus_laptop` | `/sys/devices/platform/gigabyte_laptop` |
| hwmon | `aorus_laptop-isa-0000` | `gigabyte_laptop-isa-0000` |
| DKMS | `aorus-laptop/0.2.0` | `gigabyte-laptop/0.2.0` |
| Autoload | `/etc/modules-load.d/aorus-laptop.conf` | `…/gigabyte-laptop.conf` |

**The `AORUS` strings that remain are correct and must stay** — the DMI tables
match real hardware (`DMI_MATCH("AORUS 17X")`, `DMI_MATCH("AORUS Master 18")`,
`DMI_EXACT_MATCH(DMI_PRODUCT_FAMILY, "AORUS")`) and the comments describe actual
AORUS models. Only four things named the *driver* wrongly and were changed: the
file header, the `AORUS_FAN_CTRL_*` enum (now `GIGABYTE_FAN_CTRL_*`), and the
two `pr_info` lines on load and unload.

Two consequences to keep in mind:

- **Cherry-picking from upstream now needs rename detection.** `origin/master`
  still has `aorus-laptop.c`. Git usually handles it, occasionally not.
- **The hwmon name change resets CoolerControl's device identity**, so any saved
  configuration for the old name is orphaned. Done deliberately *before* Step 4
  produced fan profiles worth keeping, which was the cheapest possible moment.

`scripts/install-dkms.sh` removes the pre-rename install — module, DKMS trees,
`/usr/src` tree, autoload entry and stale `.ko` files — before installing, so a
machine does not end up carrying both.

### Branches

| Branch | Purpose |
|---|---|
| `master` | Pristine upstream tracking. **Never commit here.** |
| `a16-5th` | Integration branch. All work lands here. |

Remotes: `origin` = upstream, `a16` = the A16 fork.

### Why the fork is ported, not merged

The fork branched at upstream `0002d21` and has 6 commits; `master` has ~60 the
fork lacks. `git diff --stat master a16/master` shows 771 changed lines in
`gigabyte-laptop.c`, most of it the fork *missing* master's work. Merging would
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

**`dkms.conf` ships `PACKAGE_VERSION="@PKGVER@"` as a template.** It is a
placeholder the distro packaging substitutes (`sed -e "s/@PKGVER@/%{version}/"`
in the RPM spec, the same in the PKGBUILD). Running `dkms ldtarball` on a
tarball built straight from the repo registers a module literally versioned
`@PKGVER@`, and the follow-up `dkms install gigabyte-laptop/0.2.0` then fails with
"Could not find module source directory". Use `scripts/install-dkms.sh`, which
substitutes the version first and cleans up any earlier registration including
that one. The canonical version is **0.2.0**, per both RPM specs and the
PKGBUILD.

```sh
sudo bash scripts/install-dkms.sh            # or --no-autoload to skip boot loading
```

**Autoload is on by default and should stay that way.** The module registers its
platform device by hand in `gigabyte_laptop_init()` and exposes no modalias
(`modinfo -F alias` is empty), so udev has nothing to match and
`/etc/modules-load.d/gigabyte-laptop.conf` is the only thing that loads it at boot.
DKMS `AUTOINSTALL="yes"` handles rebuilding across kernel updates, but it does
not load anything.

`dkms` 3.4.4 prints "Deprecated feature: CLEAN" for the `CLEAN=` line in
`dkms.conf`. Harmless; left alone to avoid diverging from upstream.

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
- ~~Probe aborts the whole module on any optional-method failure.~~ **Fixed in
  Step 1.** `gigabyte_laptop_init()` still treats a probe error as fatal, but
  probe no longer returns one for a firmware read: fan-mode detection falls back
  to normal mode with a warning, and the charging, fan-curve, custom-speed and
  light-sensor reads log and continue. Sensors are registered before probe runs,
  so partial firmware support now still yields working fans and temperatures.
- ~~Unbounded `memcpy` in the getter.~~ **Fixed in Step 1.** The core is now
  `gigabyte_laptop_get_devstate_raw(method, arg, result, size)` and clamps with
  `min_t(size_t, size, obj->buffer.length)`. Integer reads go through
  `gigabyte_laptop_get_devstate{,2}()`, typed `int *`; buffer reads go through
  `gigabyte_laptop_get_devstate_buf()` with an explicit size. Typing the integer
  wrapper flushed out a third buffer caller — `power_on_time_show()` reads
  **five** bytes — which the old `void *` signature had hidden. Buffer
  destinations are zero-initialised so a short reply cannot expose stack bytes.
- **`temp3_input` is dead on this machine, and the firmware says why.** The
  `ERAM` embedded-controller field ends with a bare terminator:

  ```asl
  OperationRegion (ERAM, EmbeddedControl, Zero, 0xFF)
  Field (ERAM, ByteAcc, Lock, Preserve) {
      Offset (0x5F), ERBD, 8,
      Offset (0x60), SMPR, 8,
      Offset (0x62)
  }
  ```

  Nothing is declared *at* `0x62` — the offset is where the field stops. So
  `ec_read(0x62)` reads an undefined EC byte and returns 0, which is why
  `temp3` shows `+0.0°C` while `temp1` tracks `k10temp` (46000 vs 46375). The
  offset came from Intel Aero/AORUS units. CPU and GPU temperature come from
  `WMBC 0xE1`/`0xE2` (`EC0.CTMP` and friends) and are unaffected.
  `ec_read(0xD)` is suspect for the same reason, but is only reached when the
  machine is already in custom fan mode at load time.
- **`power_on_time` is mislabelled on this firmware.** The driver defines
  `POWER_ON_TIME` as `0x63`, but `WMBC 0x63` on this generation returns
  `TEST[0..4] = RXCM(0xD2)..RXCM(0xD6)` — the **five CMOS bytes** that
  `WMBD 0x63` writes, not a timestamp. It read `0 1 5 5 2` here. Useful rather
  than harmful: this node *is* the pre-write CMOS snapshot that Step 6 needs, so
  that requirement is already satisfied by `cat power_on_time`.
- **`eeepc_wmi` steals our event GUID.** `/lib/modules/$(uname -r)/modules.alias`
  contains `alias wmi:ABBC0F72-8EA1-11D1-00A0-C90629100000 eeepc_wmi`. udev
  coldplugs the WMI event device, matches `eeepc_wmi`, which pulls in `asus_wmi`
  and logs `ASUS Management GUID not found`. ASUS's Eee PC interface and
  Gigabyte's AMW0 share the same AMI-derived GUID block. This must be
  blacklisted before working on the GiMate button.
- **Kernel cmdline leftovers, and `acpi_osi=Linux` is now implicated.**
  `acpi_osi=Linux acpi_enforce_resources=lax` are both leftovers from the
  earlier fan-control attempts. `acpi_enforce_resources=lax` relaxes ACPI
  resource conflict checks, which `ec_sys`-style direct EC poking needed and
  this driver does not. `acpi_osi=Linux` forces the firmware's Linux `_OSI`
  branch, and is the leading explanation for `nvidia-powerd` failing to read
  the SBIOS power-limit table — see the `perf_mode` findings under Step 2.
  Remove both.

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
| ~~0~~ | ~~DKMS install, load, verify hwmon channels appear~~ **done** | low |
| ~~1~~ | ~~Clamp the `memcpy`; make optional probe reads non-fatal~~ **done** | low |
| ~~1b~~ | ~~Extend `debug_method` to take an argument~~ **done** | low |
| 2 | Validate `0xED` / `0xE7` / `0x7D` on `GA65TH` by sentinel | medium |
| 3 | Register a `platform_profile` handler over `perf_mode` + `dynamic_boost` | low |
| 4 | Writable `pwm1`/`pwm2` for CoolerControl | medium |
| ~~5~~ | ~~GiMate button — input device + `sparse_keymap`~~ **done** | low |
| 6 | `0xF6`/`KBLL` brightness first, then RGB over `/dev/hidraw2` | high |

Steps 0, 1 and 1b are complete and verified on hardware: `gigabyte-laptop/0.2.0`
installed through DKMS, signed by the `DKMS module signing key`, loaded, with
all **18** driver attributes present including the three Gaming-only ones. The
platform device directory lists 25 entries, the other seven being device-core
(`driver`, `driver_override`, `hwmon`, `modalias`, `power`, `subsystem`,
`uevent`). With 1b done, nothing blocks Step 2.

The load log is itself free reconnaissance, because Step 1 made every optional
read report itself. On this machine it printed only `Skipping silent fan mode ID
check`, `Dual fan speed control required`, `Using old light sensor method` and
`Gigabyte laptop WMI driver started`. The absence of the other warnings means fan
mode, custom speed, charging mode, charging limit, the fan curve **and
`dynamic_boost` (`0xE7`)** all read successfully — the first on-hardware
evidence that `0xE7` is implemented here, not merely on the CWH.

### Sensors verified end to end under load

A 20-second all-core load, sampled every 2 s:

```
t=6s   87C-bound  cpu=73C  pwm1=0   fan1=0     fan2=0
t=10s             cpu=86C  pwm1=20  fan1=0     fan2=0
t=14s             cpu=88C  pwm1=24  fan1=1863  fan2=1807
t=22s             cpu=85C  pwm1=32  fan1=2500  fan2=2727
```

`temp1` matches `k10temp`, PWM rises with temperature, both fan tachometers
follow PWM and move independently. This also confirms the little-endian branch
for `GIGABYTE GAMING` is correct — a wrong byte order would give values in the
tens of thousands rather than a clean `pwm 0 → 0 RPM`, `pwm 32 → ~2500 RPM`
relationship.

Two behaviours worth knowing, both normal:

- **The fans stop entirely at idle.** `pwm1` goes to 0 and both tachs read 0
  with the CPU at 46–47 °C. Semi-passive cooling, not a failed read.
- **`fan_mode` reads `1` (silent), and the EC holds the fans off until ~86 °C
  in that mode.** That looks like a correct read rather than a misparse, and it
  is the concrete argument for Step 4: writable PWM is what would let the user
  override a fan curve that tolerates 86 °C before spinning up.

Step 2 gates everything GPU-related. Step 6 is open-ended research; treat it as
a separate project rather than a blocker.

**GiMate diagnosis order** (stop `input-remapper` first — it clones the keyboard
into `input21`/`input22` and will confuse scancode capture):

**Tested on hardware with `showkey --scancodes`:**

| Key | Result |
|---|---|
| **GiMate** | **nothing** — no scancode at all |
| **Fn+F7** ("Mode") | **nothing** |
| Fn+Space | works already, toggles the keyboard backlight |
| Fn+F12 | `e0 5b  23  a3  e0 db` = Super press, `h`, `h` release, Super release |

So the `KEY_KPEQUAL` hypothesis from the AERO X16 and GiHATE projects is
**disproven for this unit**, and the cheap userspace route — `keyd` or a udev
hwdb entry — is off the table for GiMate and Mode. Fn+Space is handled inside
the EC and needs nothing from us. Fn+F12 shows the EC synthesising ordinary key
combos for some Fn keys, which is why those work without a driver.

### Settled on hardware: the keys use the WMI path, and their event numbers

The instrumented build answered it. Pressing GiMate five times then Fn+F7 twice
produced, with **no** `GBT0005` notify at all:

```
gigabyte_laptop: WMI event: ce 00 bb cc     x5
gigabyte_laptop: WMI event: cc 00 bb cc     x2
```

So:

| Event number (`WEVN`) | Key |
|---|---|
| `0xCE` | GiMate |
| `0xCC` | Mode (Fn+F7) |

*The assignment follows the press order and is worth one confirming press each
before it is baked into a keymap.*

Three things are confirmed by that output:

- **The route is `_Q45` → `SMGR` → `WMBC(0, 0x03, n)` → `Notify (AMW0, 0xD2)`.**
  The `_Q63` → `Notify (GAPD, 0xCF)` candidate never fired, so `GBT0005` is
  eliminated for these keys despite `_STA` reporting it present.
- **The decoded event chain was right.** The payload is literally
  `{WEVN, WEVS, 0xBB, 0xCC}` — byte 0 the event number, byte 1 the state, then
  the two constant bytes. `state` is `0x00` for both keys.
- **Our driver owns the GUID**, so the absence of `GBT0005` notifies is a real
  negative rather than a lost race:
  `/sys/bus/wmi/devices/ABBC0F72-…-3/driver -> gigabyte-laptop-events`.

**Step 5 is implemented on that basis.** The driver creates an input device,
"Gigabyte laptop hotkeys", and reports both keys through `sparse_keymap` as
programmable keycodes rather than acting on them in the kernel, so GNOME and
KDE can bind them:

| Key | `WEVN` | Keycode | Typical keysym |
|---|---|---|---|
| GiMate | `0xCE` | `KEY_PROG1` (148) | `XF86Launch1`-class |
| Mode (Fn+F7) | `0xCC` | `KEY_PROG2` (149) | `XF86Launch2`-class |

`asus-wmi` uses `KEY_PROG1`..`4` for vendor keys for the same reason. Events the
keymap does not cover are still logged, so a number this firmware uses that we
have not seen can be added. Mode may *additionally* drive
`platform_profile_cycle()` once Step 3's handler exists; that is deliberately
not wired yet, so the key has one meaning rather than changing behaviour
underneath the user.

The module now depends on `sparse-keymap`, which is `CONFIG_INPUT_SPARSEKMAP=m`
on this kernel and loaded automatically as a dependency.

### The candidates, for the record

1. **`_Q63` → `Notify (GAPD, 0xCF)`** on `GBT0005`, which `_STA` reports present
   on this BIOS. An `acpi_driver` with a notify handler. Simplest of the two,
   and the Windows driver binds exactly here.
2. **`_Q45` → `SMGR(WEVN, WEVS)` → `WMBC(0, 0x03, n)` → `Notify (AMW0, 0xD2)`**,
   the generic WMI event path, and **the one these keys actually use**. The
   driver *registers* a handler as the `gigabyte-laptop-events` `wmi_driver`,
   but it only receives anything if it wins the device: `eeepc_wmi` matches the
   same GUID and only one driver binds.

   **Blacklisting is not enough on its own.** `modprobe.d` stops future loads
   but does not touch a module already resident, so after writing the blacklist
   either reboot or unbind explicitly. Then confirm ownership before treating
   silence as a negative result:

   ```sh
   ls -l /sys/bus/wmi/devices/ABBC0F72*/driver
   # must point at .../drivers/gigabyte-laptop-events
   ```

   On this machine that check passed, which is what makes the absence of
   `GBT0005` notifies meaningful rather than a lost race.
3. The `\_SB_.I2CB.ECSH` i2c-HID pipe.

**Confirmed on hardware: the keys do reach ACPI.** `gpe0A` is the EC's GPE and
its firing count is world-readable at `/sys/firmware/acpi/interrupts/gpe0A`.
Five GiMate presses plus five Fn+F7 presses took it from 137 to **157** — two
GPEs per press, make and break. A 20-second control with no keys touched showed
**zero** drift, so the count is not background EC polling.

So the EC raises a query for both keys and nothing in Linux consumes it. That
rules out the ENE pipe being the only route and makes Step 5 ordinary kernel
work: add the handler and map the event.

**The ENE i2c-HID pipe does _not_ carry the hotkeys.** `cat /dev/hidraw2` over a
20-second window with GiMate and Fn+F7 pressed produced no bytes. Combined with
the GPE result, the event path is pure ACPI. That is a useful negative: it keeps
Step 5 away from the undocumented ENE protocol entirely.

**Lockdown blocks the obvious way to name the query.** Writing
`/sys/kernel/debug/dynamic_debug/control` fails with `EPERM` even as root —
`Lockdown: tee: debugfs access is restricted`. `CONFIG_DYNAMIC_DEBUG=y` and
debugfs being mounted rw are *not* sufficient; check anything debugfs-based
against lockdown first. `/sys/module/acpi/parameters/debug_{level,layer}` are
writable and lockdown-exempt, but they are ACPICA-level and do not print the
`Query(0x%02x) scheduled` line, which comes from Linux's `ec.c` via `pr_debug`.

**So the driver carries the diagnostic instead.** Both candidate paths are
instrumented and log what they receive, so a keypress names its own path:

- `gigabyte_laptop_wmi_notify()`, reached via the WMI route, dumps the event
  buffer and breaks out byte 0 (EC event number) and byte 1 (state).
- `gigabyte_laptop_acpi_notify()`, on `GBT0005`, logs the notify value — `0xCF`
  is what `_Q63` sends.

Both registrations are non-fatal; a diagnostic must not stop the driver loading.
Watch with `journalctl -kf | grep gigabyte` while pressing the keys. The WMI path
also self-tests without any keypress, since reading method `0x03` fires
`Notify (AMW0, 0xD2)` on demand:
`echo 0x03 > debug_method && cat debug_method`.

**`wmi_install_notify_handler()` does not exist on this kernel.** It was
removed, and the only route is a `struct wmi_driver` with a `.notify` callback
bound to the event GUID by its `id_table`. That is why the module now registers
a second, event-only `wmi_driver` ("gigabyte-laptop-events") alongside the platform
driver. `.notify` is itself deprecated in favour of `.notify_new` taking a
`struct wmi_buffer`; `min_event_size` is set to 0 so events carrying no data are
still delivered.

**This makes the `eeepc_wmi` blacklist matter more.** Two drivers matching one
GUID means whichever binds first wins the device. `eeepc_wmi` currently probes
and fails, leaving `ABBC0F72` with `driver=NONE`, so our driver can take it —
but that is luck, not design. Blacklist it before relying on the handler:

```sh
printf 'blacklist eeepc_wmi\nblacklist asus_wmi\n' | sudo tee /etc/modprobe.d/gigabyte-a16.conf
```

No `MODULE_DEVICE_TABLE(wmi, ...)` is declared for the event IDs on purpose.
Binding works without it; adding one would give the module a modalias and let
udev autoload it, which is a change to load behaviour worth making separately
from this diagnostic.

Expect `0x63`/`0xCF` for the `GBT0005` path or a WMI event for the `_Q45` path;
anything else is a query not yet accounted for, and this machine's DSDT is
committed to look it up.

On USB Gigabyte models the vendor-HID path carries report ID `0x04` with
payload `00 00 84` = Mode key and `00 00 91` = GigaMate key (GigaMate's
`0414_8105.json`, corroborated byte-for-byte by GiHATE). Those handlers are all
hard-wired to USB `0414:8105` interface 2, so **none of them work here** —
GigaMate's README explicitly carves out "laptops without a Gigabyte USB
keyboard (e.g. GIGABYTE GAMING A16)". No project anywhere handles this key on a
PS/2 Gigabyte keyboard.

### Step 6 leads, in order of cost

1. **`0xF6` / `KBLL` over WMI** — brightness only, but it is read/write, in
   firmware, on AMD, and needs no reverse engineering. Do this first.
2. **`WMBD 0x63` — but it writes CMOS, not the EC.** `WXCM(i, v)` sets
   `XCMI = i; XCMD = v` over `OperationRegion (CMS1, SystemIO, 0x72, 0x02)`,
   and `RXCM(i)` sets the index then reads `XCMD` back. Ports `0x72`/`0x73` are
   the **extended CMOS index/data pair**; this machine's EC is at `0x66`/`0x62`
   (`ACPI: EC: EC_CMD/EC_SC=0x66, EC_DATA=0x62`). So `0x63` stores five bytes in
   **CMOS NVRAM**, most likely for the firmware to consume at the next boot
   rather than to drive anything live. That is a better explanation of
   GigaMate's "doesn't reach the RGB controller" result than the USB-versus-ENE
   distinction, and it lowers this lead's prospects considerably.

   Two hazards before trying it:

   - **It needs an input buffer of at least five bytes.** The body dereferences
     `Arg2[0]` through `Arg2[0x04]`, and `gigabyte_laptop_set_devstate()` passes
     `sizeof(u32)` — four. The fifth `DerefOf` would fail *after* the first four
     `WXCM` writes have already landed, leaving a **partially written CMOS
     block**. A wider setter is required first.
   - **Record the existing CMOS values with `RXCM(0xD2)`–`RXCM(0xD6)` before
     writing anything**, so the previous contents can be restored.

   The same correction applies to `GBT0005`: its `_STA` check `RXCM(0xC7)` is a
   **CMOS read**, not an EC read.
3. **The 41-byte `0x0B` pipe on `/dev/hidraw2`.** The closest precedent is the
   ASUS ITE5570 family (`vrgb` issue #1), where firmware-mode report `0x0B` and
   a separate colour report `0x05` are used over i2c-HID, and one reporter
   needed to "arm" the controller on a cold boot by writing vendor-page feature
   reports. That two-report shape is the most likely form here. `hid-feature`
   from `hidutils` lists vendor-page fields usefully.

Dead ends, confirmed: `hid-lamparray` is at v7 upstream (2026-10-20, not
merged) but keys on usage page `0x59`, and ours is `0xFF00`. OpenRGB's
LampArray detector is `REGISTER_HID_DETECTOR_PU_ONLY(..., 0x59, 0x01)` — also
page-gated, so it will not see this device. Its `GigabyteAorusLaptopController`
is USB-only on page `0xFF01` with an 8-byte report `0x08`. `opengigabyte`
supports only USB `1044:*`/`0414:*`. *All reported, not independently verified.*

## Open decisions

- **What Step 3 becomes, now that GPU TGP is unreachable.** The original design
  — `platform_profile` over `perf_mode` + `dynamic_boost` — would register a
  profile that changes nothing. Two alternatives:
  - **Profiles over fan policy instead**, mapping `quiet`/`balanced`/
    `performance` onto `fan_mode` 1/0/2. That works entirely within the EC,
    needs nothing from NVIDIA, and `tuned` already asks for those three names,
    so GNOME and KDE would switch fan behaviour immediately. It contradicts the
    "leave fan settings alone" rule, but that rule existed to protect a custom
    curve *while profiles drove the GPU*; with the GPU out of reach, leaving
    fans alone means leaving the profile inert.
  - **Drop Step 3.** Keep `perf_mode` and `dynamic_boost` as raw nodes against a
    future BIOS fix, and let fan control live entirely in Step 4's PWM.
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

The read-only half is **done, and both DSDT predictions held**. Sentinel reads
with argument `0x5A`:

```
method 0xed arg 0x5a -> 0x5a (90) [echoed argument: method not implemented]
method 0xe7 arg 0x5a -> 0x0 (0)
```

`0xED` echoes the sentinel, confirming on this machine's firmware that
performance mode is write-only exactly as the ASL said. `0xE7` does not echo,
so dynamic boost really is implemented here, and it currently reads `0` — off.
That also validates the sentinel technique itself: the two cases are now
distinguishable, which they were not before Step 1b.

### `fan_turbo` works — validated on hardware

```
before:  pwm=22  fan1=1657  fan2=1657
on:              fan1=5263  fan2=5263
off:     fan_mode restored to 1, fan_custom_speed to 0
```

**~5250 RPM**, which is this chassis's figure; the fork's CWH number was ~6500,
so porting its `>= 6000` assertion would have produced a false failure. No fan
stop at the `0xE5` duty ceiling, and the pre-turbo state came back on its own.
A 15-second load afterwards confirmed the fans still track normally
(44 °C → 88 °C, pwm 0 → 30, both fans to ~2300 RPM). The zero readings right
after turbo were the usual idle semi-passive behaviour at 44 °C, not a fault.

### `perf_mode`: our write lands, but nothing applies it

`perf_mode` 0/1/2 leaves `enforced.power.limit` at **30 W** throughout, with
the GPU at `P8`. That is *not* evidence the method does nothing. The chain is:

```
WMBD 0xED -> NPCF.ATPP etc. -> Notify (NPCF, 0xC0) -> nvidia-powerd applies TGP
```

and the last link is broken on this machine, independently of us:

```
14:44:41  nvidia-powerd: ERROR! DC power limits table is not supported
          ... 22x "Failed to get SysPwrLimitGetInfo" this boot
          ... "Client (presumably SBIOS) has requested to disable Dynamic Boost"
```

Those failures start **at boot**, long before any `perf_mode` write. Three
things follow:

- **Our side is fine.** The kernel log shows no ACPI error or exception for the
  `0xED` call, so the AML executes and the `NPCF` objects resolve. `NPCF` itself
  is only `External (_SB_.NPCF, UnknownObj)` in the DSDT — it is defined in an
  SSDT.
- **The notify is reaching `nvidia-powerd`**: its retry bursts timestamp
  exactly with the writes. It is being poked and failing, not ignoring us.
- **`SysPwrLimitGetInfo` is an SBIOS call**, so the TGP table the daemon needs
  is not being handed over.

**`acpi_osi=Linux` is ruled out.** It was the leading suspect, on the reasoning
that NVPCF interfaces are usually gated behind `_OSI("Windows ...")`. Both
leftover arguments were removed with
`grubby --update-kernel=ALL --remove-args="acpi_osi=Linux acpi_enforce_resources=lax"`
and the machine rebooted. `/proc/cmdline` confirms they are gone, and
`nvidia-powerd` fails **identically** on the clean boot:

```
16:54:10  ERROR! DC power limits table is not supported
16:54:11  ERROR! Failed to get SysPwrLimitGetInfo!!
16:54:11  CRITICAL! Failed to get SysPwrLimitGetInfo
```

`enforced.power.limit` still reads 30 W against a 50 W default. The cleanup was
worth doing regardless — both arguments were dead weight — but it was not the
cause. Do not re-litigate this one.

**A gap in the test itself, before blaming firmware.** Every reading so far was
taken with the dGPU at `P8` and drawing 3–5 W. On NVIDIA laptops
`enforced.power.limit` reflects the *currently arbitrated* limit, which at idle
can sit at a floor that no mode selection will move. The sweep has never been
run with the GPU actually busy, so "`perf_mode` changes nothing" is not yet
supported. `glxgears` and `vkcube` are both installed; drive the dGPU with
`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia`, confirm the
P-state leaves `P8`, and only then compare across modes.

**`gpu_boost` (`0x51`) has never been written.** It is the other GPU lever this
firmware offers, `WMBD`-only, and the fork reports it takes 0 or 1 on Gaming
models. It should be swept alongside `perf_mode` before concluding anything.

**Read the limit with `enforced.power.limit`.** `power.limit` returns `[N/A]`
on this driver — it maps to "Requested Power Limit". The useful numbers are
`enforced.power.limit` 30 W, `power.default_limit` 50 W,
`power.max_limit` 85 W, which matches the 30/50/85 the three modes are expected
to select.

**The load test was a red herring, and GPU TGP is closed.** A power limit is a
setting, not a measurement, so if `perf_mode` moved it the change would show at
idle too. And 30 W sits *below* the 50 W VBIOS default, which is not what
Dynamic Boost arbitration looks like — arbitration raises above base rather than
pinning under it. That pattern means capped, not idle.

Confirmed by trying to set it directly:

```
$ sudo nvidia-smi -pl 85
Changing power management limit is not supported in current scope for GPU: 00000000:01:00.0.
$ nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader
30.00 W
```

Rejected for 85, 50 and 30 alike. On laptop GPUs the platform owns TGP through
NVPCF, which is why the driver refuses manual changes — and the platform
interface is the thing that is broken, so nobody can set it. Both routes are
shut:

| Route | Result |
|---|---|
| `perf_mode` → NPCF → `nvidia-powerd` | daemon cannot initialise; SBIOS withholds the power-limit table |
| `nvidia-smi -pl` | refused, "not supported in current scope" |

**D3 and D4 are closed as blocked by firmware, not by this driver.** The WMI
write lands, the AML executes, the notify arrives; the consumer above us is
broken on BIOS FB03 with the 615.78.08 open kernel module. Nothing in
`gigabyte-laptop.c` can change that. Revisit only if a BIOS or driver update
makes `nvidia-powerd` start cleanly — the one-line check is
`journalctl -u nvidia-powerd -b | head`.

**Consequence for Step 3.** The settled design was "a profile switch sets
`perf_mode` and `dynamic_boost` only, fan settings deliberately left alone".
That rationale assumed `perf_mode` did something. With TGP unreachable, a
profile built on it would do nothing at all, so the design needs revisiting —
see Open decisions.

### `dynamic_boost` round-trips, direction still unknown

`0 -> 1 -> 0` reads back correctly, so the node and the inversion are right.
Which direction means "boost on" cannot be settled while the TGP is pinned, so
**D4 is blocked on the same thing** as D3.

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
# Dump every table and decompile all of them, not just the DSDT. AMDI0100 and
# the APMF methods are not in the DSDT, so they must be in an SSDT.
sudo acpidump -b && iasl -d dsdt.dat ssdt*.dat

# Live capture on the ECSH vendor pipe. Press GiMate / Fn+Space / Mode
# while this runs. Read-only; it only listens.
sudo timeout 20 cat /dev/hidraw2 | xxd
```

If bytes appear on `hidraw2` when GiMate is pressed, Steps 5 and 6 both open up
considerably.
