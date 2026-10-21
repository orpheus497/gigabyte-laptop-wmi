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

This is an **A16 5-series** machine. Do not apply findings from the A16
3-series (`3VH`, `3WH`) — different generation.

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
| **Not applicable** | `3VH`, `3WH` | different model line entirely |

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
- **`GBT0005:00` is resolved: ignore it.** It is `Device (GAPD)` under `\_SB`,
  and its `_STA` exists for side effects rather than to report presence. On the
  AMD firmware it latches the dGPU off when the EC says it is disabled, then
  returns `Zero`:

  ```asl
  Name (_HID, EisaId ("GBT0005"))
  Method (_STA, 0, NotSerialized) {
      If ((^^PCI0.AMW0.RXCM (0xC7) == One)) {
          ^^PCI0.GPP0.PG00._OFF ()
          ^^PCI0.GPP0.WMOF = One
      }
      Return (Zero)
  }
  ```

  Linux enumerates any `_HID`-bearing node even when `_STA` reports absent,
  which is exactly why it appears with no driver. **There is nothing for a
  Linux driver to do with it here.** (The Intel CWH variant can return `0x0F`
  and is also a notify target via `_Q63` → `Notify (GAPD, 0xCF)`, which is what
  the Windows UMDF driver listens to. The AMD path has neither.)

## Firmware reference

`GAMING-A16-3VH-DSDT.dsl` in this repo is a public DSDT from a **GAMING A16
3VH** — AMD, same `GBTUACPI` firmware generation, and the closest sibling with
public firmware. Its AML is **41,990 bytes** against this machine's **41,169**,
so it is very nearly the same table. Use it to look up method bodies and EC
field names instead of guessing.

**It is not this machine's firmware.** No public DSDT or hw-probe exists for any
`5TH`/`GA65TH` unit. Treat everything below as *probable on BIOS FB03*, and
verify with `debug_method` before relying on it.

### Method IDs present in the AMD sibling

Verified by reading the `Switch` case lists directly:

```
WMBD (write): 02 03 46 47 50 51 57 61 63 64 65 66 67 68 6A 6B 70 71 7D 80
              87 88 A1 A3 C4 C7 C9 CA CB D9 E6 E7 ED F6 FA
WMBC (read):  46 47 50 57 61 63 64 65 67 68 6A 6B 6F 70 71 7D 80 87 88 A1
              A2 A3 C4 C7 C9 CA D9 E1 E2 E3 E4 E5 E6 E7 EB EF F6
```

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
- **It is also why the module still loads.** `0xFC` (`LIGHT_SENSOR_NEW`) is
  absent from AMD firmware, and the probe does `if (ret) return ret` after that
  read, with init treating probe failure as fatal. The Default rescues it: the
  read "succeeds" with zeroes, `light_sensor_result[0] != 0xF7`, and probe
  carries on to the old light-sensor path — which is equally absent and equally
  harmless. The unbounded `memcpy` is not reachable here either, because the
  echoed buffer is only 4 bytes. Still worth clamping, but it is hygiene rather
  than a live hazard.

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
| **1b** | **Extend `debug_method` to take an argument** — prerequisite for Step 2 | low |
| 2 | Validate `0xED` / `0xE7` / `0x7D` on `GA65TH` by sentinel | medium |
| 3 | Register a `platform_profile` handler over `perf_mode` + `dynamic_boost` | low |
| 4 | Writable `pwm1`/`pwm2` for CoolerControl | medium |
| 5 | GiMate button — diagnose, then notify handler + keymap | low |
| 6 | `0xF6`/`KBLL` brightness first, then RGB over `/dev/hidraw2` | high |

Step 1 is **not** a blocker for Step 0 — the WMBC Default rescues the one
missing probe read, so the module is expected to load as committed. Step 1b
*is* a blocker for Step 2.

Step 2 gates everything GPU-related. Step 6 is open-ended research; treat it as
a separate project rather than a blocker.

**GiMate diagnosis order** (stop `input-remapper` first — it clones the keyboard
into `input21`/`input22` and will confuse scancode capture):

1. i8042 scancode — `showkey --scancodes` / `evtest /dev/input/event1`.
   **Look specifically for `KEY_KPEQUAL` (117).** Two independent sources agree
   the GiMate key presents as "Keypad Equals": the AERO X16 1VH RGB project
   reports scancode `0x70067` (HID keyboard usage `0x67`) → `KEY_KPEQUAL`, and
   the Windows GiHATE project reports PS/2 set-1 scan `0x59` / `VK_CLEAR`,
   which is the same physical key. *Reported, not verified on this unit.*
   If it emits a usable scancode, `keyd` or a udev hwdb entry solves it with no
   kernel work — and there is currently **no hwdb entry for any modern Gigabyte
   laptop** (`60-keyboard.hwdb` has only the ancient `U2442` and `i1520M`).
2. WMI notify `0xD2` on `ABBC0F72` — `acpi_listen`. Strong prior: the bundled
   AORUS DSDT fires `Notify (AMW0, 0xD2)` from inside `WMBC`
   (`AORUS-17X-VF-DSDT.dsl:125336`). The driver defines `WMI_EVENT` and never
   uses it — no `wmi_install_notify_handler`, no input device, no
   `sparse_keymap`.
3. The `\_SB_.I2CB.ECSH` i2c-HID pipe.

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
2. **`WMBD 0x63`** — writes five bytes to `WXCM 0xD2`–`0xD6`, `WMBC 0x63` reads
   them back. GigaMate's `research.md` lists this under "What Didn't Work" on an
   AERO X16 because it "doesn't reach the USB RGB controller" — but **this
   machine has no USB RGB controller**, the keyboard is behind the ENE part.
   Whether it reaches the ENE controller on a PS/2 unit is untested by anyone.
   Cheap experiment, genuinely unknown outcome. *Hypothesis, not a finding.*
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
