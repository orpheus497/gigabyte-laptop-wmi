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
  near-identical across this firmware generation, which is why
  `GAMING-A16-3VH-DSDT.dsl` in this repo ~~**is** the accepted reference~~
  **was** the reference for WMI method bodies and EC field names — *before this
  machine's own dump existed.* It is now the cross-generation comparison only.
  `GAMING-A16-5TH-DSDT.dsl` is this machine's own firmware and is authoritative;
  see "Firmware reference".

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

- **DMI matching is safe across gens, and deliberately broad.** The driver's
  match table keys on `DMI_BOARD_VENDOR` + `DMI_PRODUCT_FAMILY`
  (`GIGABYTE GAMING`), never on the gen suffix, so the gate passes regardless.
  Narrowing it to validated SKUs has been suggested and is **wrong for this
  project**: upstream supports a family, not one machine, and a `GA65TH`-only
  entry would drop every other Gigabyte Gaming model.

  It is safe because an absent method now degrades harmlessly in both
  directions, which is understood rather than hoped for. A **read** of an
  unimplemented ID hits `WMBC`'s `Default { Return (Arg2) }` and echoes the
  argument, and every such read in probe is non-fatal since Step 1. A **write**
  hits the same `Default` in `WMBD` and simply does not land. So on a
  generation lacking `0xE7`, `0xED` or `0x7D`, the nodes appear and do nothing
  — which is the same outcome as on this machine, where `0xED` is write-only
  and the TGP path is firmware-blocked. The one real risk would be a method ID
  that means something *different* on another generation, and nothing seen so
  far suggests the Gaming block is reused that way.
- **Method IDs are not safe across gens.** `0xED`, `0xE7` and `0x7D` arrived
  validated only on `CWH` — a different generation on Intel, where this is AMD
  Rembrandt. **All three have since been checked on `GA65TH`** and are recorded
  under "Step 2 validation": `0xE7` reads back, `0xED` is write-only exactly as
  the ASL predicted, and `0x7D` drives the fans to ~5250 RPM. **Every *other*
  fork-derived method ID is still unvalidated until checked on this unit via
  `debug_method`.** The fork's `~6500 RPM` turbo figure and its 55 W → 70 W TGP
  numbers remain wrong here: they are RTX 5070 values and this unit has an
  RTX 5050. The measured turbo figure on this chassis is ~5250 RPM.

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
- ~~**No platform profile is registered.**~~ *Was true before Step 3, which is
  why the slot was available.* **This driver now registers one**, named
  `gigabyte_laptop`, which also creates the legacy aggregate
  `/sys/firmware/acpi/platform_profile`. `amd_pmf` would add a second if it ever
  binds. See "Step 3: profiles over fan policy".
- **`GBT0005:00` is declared and present, but it is _not_ what the hotkeys
  use.** *Historical hypothesis, since disproven — kept because the firmware
  facts below are still accurate and the device is still a candidate for
  whatever else the Windows driver does with it.* It was a leading Step 5
  candidate until an instrumented build showed the keys arriving over WMI with
  **no `GBT0005` notify at all**; see "Settled on hardware" under Phase 3. On
  BIOS FB03 it is simply present, with no dGPU latch and no `RXCM` check:

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
  Windows UMDF driver on `ACPI\GBT0005` listens for. The GiMate key emits **no
  i8042 scancode at all** (tested), which is what made this look promising —
  but `_Q63` never fires for either key on Linux, so the `acpi_driver` route was
  not the answer. The handler is still registered as a diagnostic, and it has
  stayed silent.

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

**Only commit the tables you need, and never the whole dump.** ACPI tables are
firmware code, identical across every unit of a given model and BIOS, so a DSDT
carries nothing specific to one machine. Two tables in a full dump do:

- **`MSDM`** holds the OEM Windows licence key.
- **`SLIC`**, where present, holds OEM licensing data. (`SLIT` is the System
  Locality Information Table — NUMA distances, nothing to do with licensing.)

Neither is committed here, and `*.dat` being gitignored means a stray
`acpidump` cannot add them by accident. Per-machine identifiers such as the
serial number live in SMBIOS/DMI rather than in ACPI, and are not in these
files either.

**Treat that last sentence as a per-dump conclusion, not an axiom.** ACPI
*reserves slots* for machine-unique data even when it does not carry it — `_BIX`
has a BatterySerialNumber field, and this firmware ships a placeholder in it
that the EC overwrites at runtime (see the audit note below). It happens to be a
placeholder on both A16 dumps; it is not guaranteed to be one on the next dump
from anywhere. **Check `_BIX` specifically** when committing a new table.

**Audited 22 Oct 2026, working tree and full history, and clean. Re-run and
re-confirmed 24 Oct 2026**, across all 38 tracked files and all 435 unique blobs
in history. The re-run inverted the method, which is why it is worth recording
as more than a datestamp bump: instead of grepping for *patterns* that might
match an identifier, it took the live machine's own identifiers — hostname, both
MAC addresses, all four filesystem UUIDs, the battery identity — and grepped the
tree for each literal value. **Zero hits for every one.** No `MSDM`, `SLIC` or
`SLIT`; no asset tag or MAC address; no keys, credentials or tokens; and no
hostname anywhere in tracked content. The username `orpheus497` *does* appear
twice — the remotes table and the PR #1 link, both below — because it is the
public fork slug, which is the point of it being there.

**The one gap is closed, 29 Oct 2026 — all four clean.** The four root-only
DMI identifiers — `product_serial`, `board_serial`, `chassis_serial` and
`product_uuid`, all mode 0400 — could not be matched against the tree without a
password, which is why they sat open through two audits. Read from a privileged
shell and each searched for as a literal across tracked content: **zero hits for
all four.** Both asset tags still read "Default string".

Two details make that a real negative rather than a vacuous one. The loop skips
any value that is empty or a BIOS placeholder and says so, and **none of the
four was skipped** — so every one held a genuine value that was actually
searched, which is the failure mode a careless version of this check would hit.
And it never echoes a value to the terminal, so its output is safe to paste
anywhere:

```sh
for f in product_serial board_serial chassis_serial product_uuid; do
	v=$(sudo cat /sys/class/dmi/id/$f 2>/dev/null)
	case "$v" in ""|"Default string"|"To Be Filled"*) echo "$f: empty/placeholder"; continue;; esac
	if git grep -qI -F -- "$v"; then echo "$f: *** FOUND IN REPO ***"; else echo "$f: clean"; fi
done
```

**Scope, stated because it is narrower than the 24 Oct run:** `git grep` with no
revision searches the **tracked working tree**, not history. The 24 Oct audit
covered all 435 blobs in history, for a different set of identifiers; this one
covers the current tree only. The committed firmware has not changed since it
landed, so the two coincide for the files that could plausibly carry an
identifier — but append `$(git rev-list --all)` to the `git grep` if a stronger
guarantee is ever wanted.

Three things look alarming in a naive grep and are not:

- **`Serial` appears thousands of times in the DSDTs.** Nearly every hit is the
  AML keyword — `Serialized`, `NotSerialized`, `SerialBus`. The remainder are
  `iasl`-generated `PNP0500` comments ("Standard PC COM Serial Port") and, in
  the two Intel DSDTs, the `SerialIoUart0`–`6` device names. None is a serial
  number.
- **`ToUUID` appears throughout.** All are `_DSM`/`_OSC` *interface* UUIDs,
  which are published constants shared by every machine implementing that
  interface, not system UUIDs. The one outside an `Arg0 ==` comparison is
  Microsoft's "Generic Buttons Device" HID.
- **`"41167"` sits in the ACPI `_BIX` BatterySerialNumber slot of both A16
  DSDTs** — and it is a firmware placeholder, not this unit's data. Three
  independent reasons, which is why this is a proof rather than a reassurance:
  the live unit reports `2287`; the AML overwrites the package at runtime via
  `EC0.UB1I (STAX)`, so the literal is only what the table *ships* with; and the
  identical literal is in the public 3VH dump, from somebody else's machine.
  **This is the one serial-shaped literal in the tree**, so a future serial grep
  will hit it, which is why the proof belongs here alongside the other two
  rather than being re-derived every time.

Re-run the audit the same way after committing any new firmware dump.

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

**Bound the extraction to the method as well as the indent.** Verified
26 Oct 2026 by re-deriving both lists mechanically: a 20-space `Case (0x..)`
scan that runs past `WMBC`'s closing brace at `GAMING-A16-5TH-DSDT.dsl:9861`
picks up `Case (0x05)` from the `_DSM` Device Labeling Interface at `:10148`,
which is not a WMI method ID at all. With the scan bounded to `9672`–`9861` the
`WMBC` list above reproduces exactly, and the `WMBD` list reproduces from
`9265`–`9672`. So the rule is two-part — own indent level *and* inside the
method — and both lists above are confirmed correct.

All three ported IDs are present on **AMD** firmware, which is the main thing
Phase 2 needed: `0xED`, `0xE7`, `0x7D`.

### Methodological: a keyword search cannot prove a feature absent

**Short, and it has already cost one wrong claim.** The firmware contains
**zero** occurrences of `charg`, case-insensitive, across the whole of
`GAMING-A16-5TH-DSDT.dsl` — and charge limiting demonstrably works on this
unit, measured stopping the battery dead at 80 %. The fields are named `BCPS`
and `BCPC`, so no search for the feature's English name could ever have found
them.

Two things follow, and the second is the one that keeps biting:

- **A negative keyword result is not evidence.** It bounds nothing. This is the
  same error as `grep -c GTMP` returning `0` and being read as "there is no GPU
  temperature field", when the field is called `GPUT` — see the `temp2`
  correction under Hazards. Both were asserted in the same session.
- **The working method is the one this file already uses elsewhere**:
  enumerate the `Switch` case lists, then read the bodies. Vendor AML is named
  in four-letter EC mnemonics throughout, so the case list is the index and
  there is no searchable vocabulary above it.

### WMBC echoes unknown method IDs — this breaks naive validation

Both methods end with a catch-all:

```asl
Default { Return (Arg2) }
```

and `wmi_evaluate_method()` passes `Arg2` as a 4-byte **buffer**, so an
unimplemented ID comes back through `get_devstate2()`'s buffer branch as the
argument that was sent. Two consequences:

- **A read of an unsupported ID looks like success and returns your argument.**
  `debug_method` originally always sent `0`, so every unimplemented ID read as
  `0` — indistinguishable from a real value of `0`. **Fixed in Step 1b:** the
  node now takes `"method [arg]"`, and validation uses a **sentinel** — read
  with `0x5A`, and if `0x5A` comes back the ID is not implemented. The node says
  so itself when the result matches the argument. Step 2 was done on that basis
  and its results are trustworthy; see "Step 2 validation".

  **Parsing that node: match `[implemented]` with its brackets.** The format is

  ```c
  "method 0x%02x arg 0x%x -> 0x%x (%d) [%s]%s\n"   // %s = "implemented" or
                                                   // "not implemented: reply
                                                   //  was not an integer"
  ```

  so the *negative* string contains the word `implemented` as a substring. A
  `grep implemented` or a `*implemented*` glob therefore passes both cases and
  silently accepts an absent method. Only `[implemented]` — brackets included —
  distinguishes them. Caught in `scripts/test-charge-limit.sh`, which parsed the
  decimal out of the reply without checking the marker at all, so an absent
  `0x64`/`0x65` would have echoed the sentinel, parsed as a plausible `90`, run
  the whole ceiling test against a field nothing reads, and then "restored" 90.
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

**The echo still reaches integer callers, and the fix is five lines — located
26 Oct 2026.** The debug node tells the truth now, but ordinary reads do not:
`gigabyte_laptop_get_devstate_typed()` takes the BUFFER branch for an
unimplemented ID, `memcpy`s the echoed four-byte argument into the caller's
destination and returns **0**. Reached through `get_devstate2()` →
`get_devstate_raw()`, which passes `reply_type` as `NULL`, that destination is
an `int *`, so the node reports the argument as a value and reports success.
With the argument `0`, as every ordinary read sends, **an absent method reads
as a genuine zero.**

What makes this cheap is that the function already computes the answer: it hands
the reply's `acpi_object_type` back through `reply_type` for exactly this
purpose, and the integer wrapper is the one place that needs to pass a pointer
and refuse a non-INTEGER. Five lines in one function, not a refactor.

**It also repairs a live misdetection, which is the better argument for doing
it.** Probe's silent-fan-mode detection reads `FAN_SILENT_OLD` (`0xFA`) with
argument `0` and branches on `if (ret || output < 0)`. `0xFA` has no `WMBC`
case, so the echo gives `ret == 0` and `output == 0`, and the code takes the
*"Older model detected, using old ID"* branch and installs `0xFA` as the silent
fan method — on firmware that does not implement it. It is hidden on this
machine by the early `goto obtain_fan_mode` that short-circuits the three known
DMI families before the read happens.

**But it is not demonstrable on any firmware held — checked 29 Oct 2026, and
this corrects an overstatement that stood here.** The claim was that the
misdetection "is wrong on every machine that reaches it". That needs both halves
to hold and the second one fails. The machines that *reach* the read are the
ones outside the early exit: family `AERO` or `Intel`, plus the legacy
`Aero 14` / `P64V6` / `P64V7` entries — all old Aero and P-series. The one dump
from that range is `Aero-15-Classic-DSDT.dsl`, and it carries `Case (0xFA)`
**twice**: `:60113` inside `WMBD` (which opens at `:60109`) and `:60296` inside
`WMBC` (which opens at `:60285`). `WMBC` implements it there, so the read
returns a real integer and the detection works. On the Gaming dumps `0xFA`
appears once — `:9269` on the 5TH, inside `WMBD` — so a read *would* echo, but
those machines take the early exit and never make it.

**So across every firmware in this repo, either the read works or it is never
performed.** The hole in `get_devstate2()` is still real and still worth
closing: an unimplemented ID reads back as a genuine `0` with a success return.
But it is a latent correctness hole, not the repair of a live misdetection, and
writing it up as the latter is exactly the overstatement this file warns about
elsewhere.

**The type test has one theoretical blind spot, and it is empty across all four
committed dumps — checked 26 Oct 2026.** A firmware case that returned the
untouched `Arg2` buffer would answer exactly like `Default { Return (Arg2) }`,
so `gigabyte_laptop_method_implemented()` would call it absent. The only
non-`Default` `Return (Arg2)` anywhere in the four dumps is
`AORUS-17X-VF-DSDT.dsl:125350-125354`, `WMBC Case (0xE6)` — and it does
`Arg2 = RXCM (0x12)` first, overwriting the argument object with an Integer, so
it answers INTEGER and is correctly detected. **The gate is sound on every
firmware we hold.** Recorded as a bound on the technique rather than a defect,
and worth re-checking against any new dump: it is the one way the test can lie.

### A third of WMBD's setters return nothing, and that read as failure

The mirror image of the WMBC echo problem, found from a spurious warning in the
load log and then confirmed against the DSDT. `WMBD` cases split two ways:

```asl
Case (0x71) { ^^SBRG.EC0.GFAN = Zero
              ^^SBRG.EC0.FANB = Arg2
              Return (^^SBRG.EC0.FANB) }     // returns a value

Case (0x7D) { ^^SBRG.EC0.TFAN = Arg2 }       // assigns and falls out
```

Counted at the switch's own indent level:

```
return a value (22):  46 47 50 57 61 64 65 66 67 68 6A 6B 70 71 80 87 88 A1 C4 CA E7 F6
return NOTHING (11):  51 63 7D A3 C7 C9 CB D9 E6 ED FA
```

`wmi_evaluate_method()` succeeds for a void method but leaves the reply buffer
empty, so `gigabyte_laptop_set_devstate()` found no integer and returned
`-EINVAL` — **after the EC field had already been assigned.** Three of the
eleven are written by this driver:

| ID | Node | What the spurious failure did |
|---|---|---|
| `0xED` | `perf_mode` | Every write returned `-EINVAL` to userspace and never cached the value, so the node could not report the mode it had just set |
| `0x51` | `gpu_boost` | Same |
| `0x7D` | `fan_turbo` | Logged "Could not clear the turbo fan bit" on a clear that had in fact succeeded |

**Fixed: any successful ACPI evaluation is a successful write.** `*result` takes
the integer when there is one and `0` otherwise, and nothing else is inferred
from the reply.

A first attempt tried to be cleverer and **was wrong on hardware.** It returned
`-EOPNOTSUPP` for a buffer reply, reasoning that `WMBD` ends in
`Default { Return (Arg2) }` with `Arg2` passed as a 4-byte buffer, so a buffer
back meant no case for that ID — the write-side mirror of the WMBC sentinel.
Then `echo '0x7D 1' > debug_method_write` reported "not implemented" and
`WMBC 0x7D` read back **`1`**: the write had landed. So a void case *also*
answers with a non-integer, and the two are not distinguishable from the reply.

There is nothing after `WMBD`'s `Switch` — no trailing `Return` — which is why a
case that falls through has no value of its own to give back. **For a setter the
ACPI status is the only trustworthy signal**, and that is now all this relies on.
`debug_method_write` shows the raw reply type so a human can judge, and says to
check the EC field, which is the only thing that actually settles it.

Two consequences worth carrying forward:

- **This probably explains the fork's `fan_turbo` history.** Phase 2 notes that
  writing `0x7D` on enable "did not hold the fans" on the CWH, which is why
  turbo latches a duty plus fixed mode instead. A write that returned `-EINVAL`
  while actually landing would look exactly like a method that does nothing.
  Worth re-testing `0x7D` on its own now that the write reports honestly.
- **`perf_mode`'s TGP conclusion is unaffected.** The writes were landing all
  along — the AML executes before the method returns — so "firmware blocks the
  TGP path" still stands. What changes is that the node now reports success and
  caches, instead of erroring on every write.

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
| `0x6D`/`0x6E` | `battery_cycle` | Absent from both. Reads return the echoed argument, i.e. `0`, not an error. The real cycle count is at `BAT1/cycle_count` — see "The four nodes that read nothing". |

One caveat on `dynamic_boost` that the firmware cannot settle: the ASL proves
the node **round-trips** (`write 0` → `DBAC = 1` → reads back `1`), but not
which direction means "boost on". That rests on the fork's testing on a CWH.
~~Confirm against `nvidia-smi` in Step 2~~ — **the round-trip was confirmed in
Step 2 and the direction cannot be**, because `nvidia-smi` reads a TGP that is
pinned, so there is nothing for a toggle to move. It stays unresolvable here
until `nvidia-powerd` initialises; see "`dynamic_boost` round-trips, direction
still unknown". If it is backwards, the node is self-consistent but semantically
inverted.

~~Because `perf_mode` is write-only, the `platform_profile` handler's `probe`
must **write** a known profile to make its cached value truthful.~~ **Moot: the
handler shipped over `fan_mode`, not `perf_mode`.** `fan_mode` reads back
perfectly well, so `gigabyte_laptop_profile_probe()` *reads* the mode the
firmware is already in and writes nothing — closer to what `dell-pc.c` does with
its own resync than the forced write this note anticipated.

### Method IDs we are not using yet

Worth knowing these exist on AMD firmware, all verified in both directions
unless noted.

**`EC0.<field>` in this table means the ACPI scope, not the bus.** Most of these
fields live in `OperationRegion (PECM, SystemMemory, 0xFC7E0800, 0x1000)`, which
is a memory-mapped window, *not* the `ERAM` `EmbeddedControl` region. Two
consequences, both already bitten once:

- **`ec_read()` cannot reach them.** That is the distinction that killed
  `temp3_input`, and it applies here too: WMI is the only route.
- **A WMBD case that writes a field and returns it reads back the byte it just
  wrote.** It proves the ACPI store landed. It proves nothing about whether the
  embedded controller read it, accepted it, or acted on it. Only observed
  behaviour does that.

**There are eighteen of them, and the list is now complete.** Derived
26 Oct 2026 by diffing the firmware's own top-level case lists against the
driver's `#define`s: the firmware implements **42** method IDs and the driver
names 32, of which 10 are absent here, leaving **18** implemented commands
nothing in the driver touches:

```
61 66 6F 80 87 88 A1 A2 A3 C4 C7 C9 CB D9 E3 E6 EB EF
```

| ID | EC field | What it is |
|---|---|---|
| `0xF6` | `KBLL` (8-bit, **`PECM`**) | **Keyboard backlight brightness**, read *and* write. Verified: `Case (0xF6)` exists in both WMBD (9286) and WMBC (9691). |
| `0xD9` | `EC0.KBAT` (**1 bit**, `:8192`) | Keyboard backlight auto-off. ~~auto/timeout~~ — **"timeout" is wrong, corrected 26 Oct 2026**: the field is one bit wide, written at `:9620-9623` and read at `:9818-9821`, and there is nowhere to put a number of seconds and no table of preset delays anywhere near it. Whatever delay the controller uses is fixed inside the EC and is not adjustable. **Of the four committed dumps only the two A16 ones have this command at all**, so a runtime capability gate is mandatory rather than a nicety |
| `0xC9` | `EC0.FNKS` | Fn-lock |
| `0xC7` | `EC0.MUTE` | Mute status |
| `0x87` / `0x88` | `EC0.PLED` / `EC0.BLED` | Power LED / battery LED. Both **invert** — writing `0` sets the field to `One` — and both persist the choice to extended CMOS alongside the live field: `0x87` → `WXCM (0xDA, …)` (`:9632-9646`), `0x88` → `WXCM (0xD9, …)` (`:9648-9662`) |
| `0xE6` | **CMOS `0xD0`**, not EC | **dGPU display MUX.** `WXCM (0xD0, Arg2)` out (`:9279`), `RXCM (0xD0) & 0x7F` back (`:9685`) — **extended CMOS consumed at the next boot**, like `0x63`, not a live EC field, so the "EC field" column header does not apply. ~~0 dynamic, 1 discrete, 2 MS-Hybrid~~ — **that encoding was unsourced and is withdrawn 29 Oct 2026**; the AML decodes nothing, and the `& 0x7F` mask means bit 7 carries something unidentified. **One value is now anchored:** `0x00`, read 29 Oct 2026 while the panel was independently confirmed on the iGPU. See "`DPMF` is the display-MUX flag" |
| `0x63` | `WXCM 0xD2`–`0xD6` | Five bytes in, five back. RGB-shaped, see Step 6 |
| `0x66` | `EC0.FLVL` (8-bit) | Current fan **step**, the index into the curve the EC is using |
| `0x6B` | `EC0.FAN1` (8-bit) | CPU fan fixed duty. The driver calls this `FAN_CUSTOM_SPEED`; GCC uses it as the CPU side of its Max-mode recipe |
| `0x6F` | `EC0.FAN1` (8-bit) | **WMBC only** (`:9743`) — a second read of the same `FAN1` that `0x6B` writes |
| `0x57` | `EC0.CRAF` (1-bit) | The driver's `FAN_SILENT_MODE`, and **already driven** — `CRAF` reads `1` whenever `fan_mode` is 1. ~~Never tried as a control here~~: what is untried is GCC's four-flag *combination* with `FANB`/`TENF`/`ADJF`, not the field. See "Open decisions" |
| `0x80` | `EC0.PL3E` (1 bit, `:8121`) | A power-limit enable bit, read *and* write (`:9283`, `:9753`). Adjacent to the `ECPT` work in Step 7 and worth reading before and after that sweep |
| `0xC4` | `EC0.LCDO` (1 bit, `:8148`) | Read *and* write (`:9324`, `:9755`). Panel/LCD output. **Do not poke it blind** — a bit that may blank the display is the wrong thing to probe from a shell you are reading the result in |
| `0xCB` | `EC0.WINK` (1 bit, `:8238`) | **Write-only**, and it sets `DBG8 = 0xEA` first (`:9272-9276`). Purpose unidentified |
| `0xA1` | — / `GV04` | Asymmetric: **WMBD** returns a bare `One` (`:9624`), a stub; **WMBC** returns `GV04` (`:9689`), a 1-bit field at offset `0x12` of `OperationRegion (GSMG, SystemMemory, 0xFED81500, …)` — the AMD GPIO bank, so this is a live pin read, not a presence probe |
| `0xA2` | `EC0.ACST & 0x04` | Bit 2 of the AC-status byte, read-only (`:9816`). Not the same bit the battery path uses |
| `0xA3` | **CMOS `0xD1`**, not EC | `WXCM (0xD1, Arg2)` out (`:9618`), `Return (RXCM (0xD1))` back (`:9812`). **Purpose appears nowhere in the firmware**, and it is the one unidentified extended-settings slot — see the slot map below, and the `usb_charge` verdict |
| `0xEB` | — | **WMBC only**, `Return (One)` (`:9822`). A genuine stub or presence probe |
| `0xEF` | `~EC0.LIDF` | Lid state, **inverted** by the firmware (`:9707`). Read-only |
| `0x61` | `EC0.BHEA` (8-bit, `:8154`) | Battery health. **Read-only in both methods** — the `WMBD` case also just returns the field without writing it (`:9612`), which is a read dressed as a setter |
| `0xE3` | `EC0.SKTC` | The *same* field `0xE2` returns. See the `temp2` correction under Hazards |
| `0x03` | — | Fires the WMI event synthetically: `WMBC(0, 0x03, n)` → `Notify (AMW0, 0xD2)` |

`0xF6` is the significant one: **keyboard backlight brightness is reachable
over WMI on AMD A16 firmware**, independent of the ENE colour protocol. Nowng's
AERO X16 fork already implements it as a `keyboard_brightness` node.

#### The extended-settings slot map, and the one unidentified entry

Nine CMOS/NVRAM indices are touched through `WXCM`/`RXCM`, and knowing which
are accounted for is what makes the odd one out interesting. **These are
consumed at the next boot, not live EC fields** — the distinction that already
caught `0x63` and `0xE6`.

| Index | Written by | What it holds |
|---|---|---|
| `0xD0` | `0xE6` | dGPU display MUX. Read masks with `& 0x7F`. Measured `0x00` on 29 Oct 2026 with the panel on the iGPU; no other value observed, and the full encoding is unknown |
| `0xD1` | `0xA3` | **Unidentified.** Read/write, and its purpose appears nowhere in the firmware |
| `0xD2`–`0xD6` | `0x63` | The five-byte block behind the misnamed `power_on_time` node |
| `0xD9` | `0x88` | Battery LED, the persistent copy of `BLED` |
| `0xDA` | `0x87` | Power LED, the persistent copy of `PLED` |

`0xD9` and `0xDA` were listed as untraced and are not: each is written twice
inside its LED case, once per branch, and never read back — the live `EC0.BLED`
/ `EC0.PLED` field is what the EC acts on and the CMOS byte is what survives a
boot.

**`0xD1` is the only genuinely unknown slot**, which makes it the sole remaining
candidate for a BIOS-level toggle such as USB sleep charging. Identifying it
costs nothing and no code: read `0xA3`, change the relevant option in BIOS
setup, read `0xA3` again. It piggybacks on any reboot that is happening anyway.

### The four nodes that read nothing — and they are four different cases

**Enumerated 26 Oct 2026, and the point is that they are not one problem.**
Four driver attributes sit on method IDs this firmware does not implement, and
a blanket "four inert nodes" is the wrong summary: one is **redundant**, one is
**impossible**, and two are **open with a concrete next step**. The verdicts
differ and so should the work.

They are also not inventions. All six IDs behind them exist on the older
Gigabyte firmware the driver grew up on, and on neither A16 dump — so these are
Aero/AORUS-era commands the Gaming generation dropped:

| ID | Aero 15 | AORUS 17X | A16 3VH | A16 5TH |
|---|---|---|---|---|
| `0x6D` / `0x6E` `battery_cycle` | `CYC2` / `CYC1` | present | — | — |
| `0x7A` / `0x7B` `usb_charge_s3` / `_s4` | `S3UC` / `S4UC` (1 bit each) | `0x7A` only | — | — |
| `0xF7` / `0xFC` `light_sensor` | `0xF7` (`LUXM`) | both | — | — |

**`battery_cycle` — redundant, not broken. The data already works.** The driver
reads `BATT_CYCLE 0x6E` and `BATT_CYCLE2 0x6D`, neither of which exists here,
but **the firmware reports cycle count by the standard route**: `EC0.BCYC`, 16
bits at `:8037`, is written into the battery information package at index 8
(`:8757`), which is where the ACPI spec puts Cycle Count. `BAT1` is an ordinary
control-method battery (`PNP0C0A`, `:8778`), so the kernel's own battery driver
picks it up with no help from us:

```
/sys/class/power_supply/BAT1/cycle_count   ->   19
```

So there is nothing to research and nothing to build. **Record the path and
leave the node alone.** If it is ever gated at runtime, the gate must be
`&&`, not `||`: `battery_cycle_show()` reads both IDs and returns on the
**first** failure, so an `||` gate plus the typed-read fix above would leave a
visible node that always errors. `probe` already uses `&&` for the charging
pair, which is the shape to copy.

**`light_sensor` — impossible on this machine. Closed.** Both method IDs are
absent, and so is every standard route: no `ACPI0008`, no `_ALI`, no `_ALR`
anywhere in the DSDT; no `/sys/bus/iio` at all on this kernel; `acpi_als` not
loaded and nothing matching `*als*`. The one suggestive name, `ALST` at `:412`,
is a byte inside `OperationRegion (GNVS, SystemMemory, 0xB8065D18, 0x0D)` — a
13-byte BIOS settings area — with exactly **one** reference, its own
declaration. That is an unused BIOS variable slot, not a sensor interface. **The
hardware is not there**; this is not a driver gap.

**`usb_charge_s3_toggle` / `usb_charge_s4_toggle` — open, with exactly one
lead.** `USB_SLEEP 0x7A` and `USB_HIBERNATE 0x7B` are both absent, and there is
no live EC field for the feature either: `EC0.USBC`, 8 bits at `:8117`, has one
reference — its own declaration, the same dead-slot pattern as `ALST`. `USB1`
and `USB3` at `:4199-4201` are a red herring; they are PCI interrupt routing,
written by `INTC` alongside `PIRC` at `:4266-4267`.

**The lead is CMOS slot `0xD1` via command `0xA3`**, from the slot map above: it
is the only extended-settings index in this firmware whose purpose appears
nowhere in it, which is exactly the shape of a BIOS-menu toggle. Sleep-charging
is a setup option on these machines, and a setup option is stored in extended
CMOS. Identify it the cheap way — read `0xA3`, flip the BIOS option, read it
again — before writing a line of code against it.

### `DPMF` is the display-MUX flag, and it gates `gpu_boost` — 29 Oct 2026

**This machine advertises a MUX switch in Windows and in Gigabyte Control
Centre, and the firmware plumbing for it is all here.** It was decoded after
asking whether `0x51`'s values 3 and 4 relate to enabling and disabling the
dGPU. They do, and the picture is bigger than that node.

**What `DPMF` is, proven rather than guessed.** The brightness-key handlers
`_Q11` and `_Q12` (`:8368-8394`) branch on it to decide which GPU owns the
internal panel:

```asl
If ((DPMF != 0x02)) { Notify (^^^GP17.VGA.LCD,   0x87) }   // AMD iGPU's panel
Else                { Notify (^^^GPP0.PEGP.EDP1, 0x87) }   // NVIDIA dGPU's eDP
```

`GP17.VGA` is the Rembrandt iGPU and owns `_DOD`/`_DOS` (`:2618-2625`);
`GPP0.PEGP` is the RTX 5050. So **`DPMF == 2` means the panel is routed to the
discrete GPU** and anything else means it is on the integrated one. `DPMF` is
`External (_SB_.PCI0.SBRG.EC0_.DPMF)` here, declared in a table not committed,
so it cannot be read from this dump.

**It does not need to be. The MUX state is readable for free, with no root and
no WMI call**, which is the most useful practical result of this work:

```
/sys/class/drm/card1-eDP-1   amdgpu   status=connected      <- panel on iGPU
/sys/class/drm/card0-eDP-2   nvidia   status=disconnected
```

Read 29 Oct 2026. The dGPU *has* an eDP connector — the hardware can route the
panel either way, which is the MUX — and nothing is attached to it. So this
machine currently sits at `DPMF != 2`.

**Consequence, and it closes an open question: `gpu_boost` is not inert here.**
The whole of `WMBD Case (0x51)` sits inside `If ((DPMF != 0x02))` (`:9549`).
That gate was recorded as "a further unknown" because `DPMF` could not be read.
The connector status answers it: the gate is **passing** today, so the node's
writes do reach the firmware. If the MUX were ever switched to discrete, the
entire case would be skipped and `gpu_boost` would silently do nothing.

**The firmware interlock is the elegant part.** You cannot detach the GPU that
is driving your screen, and the firmware enforces that itself rather than
trusting the caller — the eject branch is unreachable precisely when it would
black the display.

**Two separate mechanisms, routinely conflated:**

| | Boot-time MUX | Runtime attach/detach |
|---|---|---|
| Method | `0xE6` → `WXCM (0xD0, Arg2)` (`:9279`), read `RXCM (0xD0) & 0x7F` (`:9685`) | `0x51` values **3** and **4** (`:9566-9586`) |
| Storage | extended CMOS, consumed at next boot | live, immediate |
| Effect | which GPU drives the panel | whether the dGPU is on the PCI bus at all |
| In the driver | **not implemented at all** | 3 permitted, 4 blocked — backwards |

**The `0xE6` encoding in the method table above is unsourced.** "0 dynamic,
1 discrete, 2 MS-Hybrid" is asserted there with no evidence; the AML shows only
a byte in and a masked byte out, and the `& 0x7F` means bit 7 carries something
else that nobody has identified. **Do not write `0xE6` on the strength of that
row** — a wrong value is consumed at the next boot and could route the panel to
a GPU whose driver is not up.

**The read was taken on 29 Oct 2026 and anchors exactly one value:**

```
method 0xe6 arg 0x0 -> 0x0 (0) [implemented]
```

`[implemented]` with its brackets, so this is a genuine INTEGER reply and not
the `Default { Return (Arg2) }` echo — which matters here because the argument
sent was also `0`. Taken while the connector check above independently showed
the panel on the iGPU. So **`0x00` means panel-on-iGPU with the dGPU present on
the bus**, and that is the whole of what is known. It does **not** confirm any
three-way labelling: a single observation of one state cannot distinguish
"0 = dynamic" from "0 = hybrid" or from any other scheme. The remaining values
stay unknown until one is observed from a known state, which is what a BIOS
setup option would give for free if this firmware exposes one.

**The EC can do the detach and attach by itself, with no WMI involved.** Found
on both Gaming dumps:

```asl
Method (_Q48) { Notify (^^^GPP0.PEGP, 0x03) }              // eject
Method (_Q49) { ^^^GPP0.PG00._ON () ; Notify (PCI0, Zero) } // restore
```

Note `_Q49` calls `PG00._ON()` (the slot's power gate) where `WMBD 0x51`
value 4 calls `PEGP._ON()` (the GPU) after testing `GPP0.D0ST == 0x03`. Not
interchangeable, and the WMI path is the more careful of the two.

**This reframes the `gpu_boost` bound fix.** It is not primarily a safety
patch. **3 and 4 are a matched pair implementing a feature this machine
advertises**, and the driver currently permits the destructive half and blocks
the recovery half. That is the argument to use.

**Linux already offers a weaker form of the same thing**, which belongs in any
comparison: `/sys/bus/pci/devices/0000:01:00.0/remove` plus
`/sys/bus/pci/rescan`, both present. What the firmware route adds is the power
gate — `PG00._ON` / `PEGP._ON` imply a rail the PCI layer does not touch.
Runtime D3 is also already working (`Runtime D3 status: Enabled
(fine-grained)`), so the power case for ejecting at all needs measuring before
any of this is built.

**Unidentified, found alongside:** `DNLV`, an 8-bit EC field (`:8119`), drives
`_Q44` (`:8455-8482`) to send one of five distinct notifies — `0xD1` through
`0xD5` — to the dGPU. Purpose unconfirmed; the shape suggests a level or state
index being reported to the NVIDIA driver.

### The `ERCD` general EC mailbox — found 24 Oct 2026, and **do not drive it**

`WMBC`/`WMBD` are not the EC's only interface, and knowing that reframes what is
and is not reachable here. `GAMING-A16-5TH-DSDT.dsl:8643` declares a full
command mailbox: **1 command byte plus 5 data bytes in, 8 bytes out**, with a
busy/complete handshake (`ECTB`, `ECTE`, a 100-tick `Sleep (0x0A)` spin) and
every caller serialised on `Mutex (CSMX, 0x00)` one line above it.

It is how the firmware does what WMI cannot express. `ECPT()` writes the APU
power limits through it (see "`perf_mode` has a second half"), `ECPL()` reads
the power class through it, and ACPI's own battery queries and `_REG` handler
use it at EC bring-up.

**No WMI method exposes it**, and the two obvious routes are shut: its registers
are in the memory-mapped `ECCD` window at `0xFC7E0800`, so `ec_read()` cannot
reach them for the same reason it cannot reach `PECM`, and `/dev/mem` is closed
under lockdown. A kernel driver *could* `ioremap` that window — which is exactly
why this is recorded as a prohibition rather than a lead.

**The blocker is safety, not access.** There is no mechanism by which a
kernel-side writer can serialise against AML holding `CSMX`: the mutex is an
ACPI object, acquired inside the interpreter, and nothing in a platform driver
can take it. Interleaving a write into a mailbox transaction that ACPI is
mid-way through would corrupt a battery query or an EC bring-up sequence, and
those are not failures that announce themselves. **Prefer finding a WMI wrapper
for anything wanted here.** If it is ever attempted anyway, the first step is
read-only — map the window and read `ERN1`..`ERN8` without ever setting `ECTE`
— and the mutex problem needs an answer first, not after.

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
accelerator-performance → platform_profile=performance
```

Those five are the complete set — `grep -rln platform_profile
/usr/lib/tuned/profiles/` finds no others. A profile that only `include=`s one
of them, as `balanced-battery` includes `balanced`, inherits its row rather than
adding one.

So the minimum set the handler must expose is `low-power` (or `quiet`),
`balanced`, `performance`. The moment the driver registers, the existing `tuned`
setup starts driving it with no further configuration — **verified on
hardware**, see "Step 3: profiles over fan policy".

What it drives is **fan policy**, not GPU TGP. This paragraph originally read
"a 1:1 fit with `perf_mode` 0/1/2 … starts switching GPU TGP", which was the
plan before the TGP path turned out to be blocked in firmware. The shipped
handler maps these names to `fan_mode`, and the driver exposes a fourth choice
(`low-power` *and* `quiet`) so the reverse translation for the desktop indicator
works; the mapping table is under "Step 3 design: profiles over fan policy".

`tuned` also contains a power-profiles-daemon D-Bus shim, so GNOME/KDE's power
menu works through it; `power-profiles-daemon` itself is **not** wanted.

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
governs ~~GPU TGP and fans~~ **fan policy** — the shipped handler never reached
GPU TGP. Consequences to design around: the legacy aggregate
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

### A `.gitignore` entry does not untrack a file that is already tracked

`tools/gigabyte-fan-preset-notify` — a 13 KB unstripped ELF — was committed in
`7f0f8d5`. ~~The same commit added `tools/.gitignore` listing it on line 1.~~
**Mis-attributed: `7f0f8d5` added no `.gitignore` at all.** The rule arrived one
commit later in `fc61b85` — which is a sharper illustration than the original
version of this note, because `fc61b85` added the ignore rule *and* re-committed
the same binary in one commit. Ignore rules are only consulted for *untracked*
paths, so a binary that was already staged sails straight past the rule meant to
stop it. It stayed
invisible because `git status` is quiet about tracked files and the build
rewrites it in place; `make clean` is what exposed it, as a deletion.

Untracked with `git rm --cached` (the blob stays in history, which is not worth
a rewrite for 13 KB). **That parenthetical read "on a pushed branch", which was
true when written and is not now.** The commits carrying the blob *were* pushed,
as `a16-5th-kbd-charge-uevent`; origin deleted that branch head after the squash
merge, so the two 13304-byte blobs now survive publicly only as GitHub's
`refs/pull/2/head`. Measured 24 Oct 2026, and neither half of that is an
assumption: an unauthenticated fetch of that ref **does** still serve both
blobs, while a real anonymous `git clone` of the fork retrieves neither. So
nothing a local rewrite can do would remove them, and nothing a normal clone
does would retrieve them. The check, for any generated file:

```sh
git ls-files tools/          # a build artifact here is a mistake
```

CodeRabbit listed it among the files it reviewed, which is the other tell — a
review that reports a compiled binary as a reviewed file is reporting a repo
defect, not a review.

### Branches

| Branch | Purpose |
|---|---|
| `master` | Pristine upstream tracking. **Never commit here.** |
| `a16-5th-gmate` | **Integration branch. All work lands here.** |
| `a16-5th` | Retired 24 Oct 2026. Local only; deleted on the fork. **Do not delete.** |
| `a16-5th-kbd-charge-uevent` | PR #2's feature branch, merged. Local only; deleted on the fork. **Do not delete.** |
| `p4-rem-a15` | Scratch branch cut from `7a54031`, **and the checkout is on it.** No upstream configured — the same trap as the two retired branches, below. |

**The integration branch changed on 24 Oct 2026, and the old name is a trap.**
PR #3 squash-merged the whole of `a16-5th` onto `a16-5th-gmate` as `8dad4e1`,
and the remote `a16-5th` was then deleted. So `a16-5th-gmate` carries every
change and is where work goes; the local `a16-5th` still sits at `e33932d` with
the same content but is no longer pushed or tracked.

Three consequences worth knowing:

- **The history is now a flat shape on upstream's baseline**, not sixty-one
  commits: `4b817ea` → `8dad4e1` (the squash) → incremental work. The *shape* is
  the durable fact and the count is not — it was three the day this was written
  and seven two days later — so read it off `git log --oneline 4b817ea..HEAD`
  rather than from here. That shape is a better base for extracting an upstream
  patch series than the integration history was, which is the point of having
  done it.
- **`git checkout a16-5th` looks right and is wrong.** Its tracking ref is gone
  (`"upstream is gone"` on checkout), so a commit landing there goes nowhere.
  Check `git rev-parse --abbrev-ref HEAD` before committing; this mistake has
  already been made once, immediately after the merge.
  `a16-5th-kbd-charge-uevent` carries the identical trap for the same reason.

  **And the checkout has been sitting in exactly that state since 26 Oct 2026**
  — on `p4-rem-a15`, at `7a54031`, with `git rev-parse --abbrev-ref '@{u}'`
  answering `fatal: no upstream configured`. It is content-identical to
  `a16-5th-gmate`, which is what makes it invisible: everything builds, every
  diff looks right, and a commit landing there is not on the integration
  branch and is not pushed anywhere. The check is the same one-liner this
  bullet already prescribes, which is the whole point of recording the
  recurrence rather than just the branch.
- **Neither retired branch may be deleted**, which is why both are in the table
  rather than on a cleanup list: **they are the sole surviving refs for history
  this file cites.** `920ca3b` and `75f870d` are reachable only from those two;
  `fc61b85`, `7e0ad94` and `1e3fc39` only from `a16-5th-kbd-charge-uevent`; and
  `de94609` only from `a16-5th`. None is an ancestor of `HEAD`. Delete either
  and those hashes stop resolving at the next `gc`, taking the evidence for the
  CI and review sections below with them. Tag `e33932d` first if they ever
  genuinely need to go.

Remotes, all three present:

| Remote | Points at | Role |
|---|---|---|
| `origin` | `orpheus497/gigabyte-laptop-wmi` | **our fork — push here** |
| `upstream` | `tangalbert919/gigabyte-laptop-wmi` | the project this forks; fetch only |
| `a16` | `JoseLopez36/gigabyte-laptop-wmi-A16` | the A16 fork Phase 2 ported from |

Note the naming: `upstream` is the *project*, not `origin`. A habitual
`git fetch origin && git rebase origin/master` therefore rebases onto our own
fork, not the project. Upstream updates come from
`git fetch upstream && git log upstream/master`.

`master` still sits at upstream's `4b817ea`, untouched — verified after the
PR #3 merge on both the local and the fork copy. The never-merge rule covers
`master` only, and PR #3's base was the scratch branch, which is why merging it
was safe.

### How reviews work on this fork (and PR #1, the first review surface)

[`orpheus497/gigabyte-laptop-wmi#1`](https://github.com/orpheus497/gigabyte-laptop-wmi/pull/1)
— "[WIP] Functionality for Gigabyte Gaming A16 5th", `master <- a16-5th` — existed
to be a place CodeRabbit reviewed and the diff could be read, never to be merged.
**Closed without merging on 2026-10-21**, which honoured that: `merged=False`,
and `master` is still exactly upstream's `4b817ea` on both the local and the fork
copy. Verified, not assumed.

**The never-merge rule is the durable part and still stands.** Merging the
integration branch onto `master` would cost exactly what the table above
protects: `git log upstream/master` stops being a clean comparison, the
cherry-pick strategy loses its baseline, and the eventual upstream patch series
gets harder to extract from a fork point that no longer exists. If a merge is
ever wanted, preserve the baseline first — `git branch upstream-pristine 4b817ea`
— and record the decision here.

What the surface produced while it was open: one full-diff review (29 files) and
one incremental one, four actionable findings, three acted on and one declined
with reasons. All four are described below under the commits that closed them.

To get another review later, reopen that PR or raise a fresh one from
`a16-5th-gmate` — to a scratch branch, not `master`. Two things to expect, both
learned the hard way:

- **Reviews are manual-trigger on this fork**, so expect to ask for every one.
  Two reasons were recorded; only the first still applies:
  - *"fewer than 10 stars"* — the free tier does not auto-review small repos.
    The fork has **0** stars, checked 26 Oct 2026, so this one is not close to
    lapsing.
  - ~~*"Auto reviews are disabled on base/target branches other than the
    default branch"* — the fork's default branch is `master`, so any PR based
    on the integration branch is skipped.~~ **Half stale as of 26 Oct 2026:
    the fork's default branch is now `a16-5th-gmate`**, so a PR targeting the
    integration branch is no longer skipped *for this reason*. It was a real
    observation at the time — seen on PR #2
    (`a16-5th <- a16-5th-kbd-charge-uevent`) — and the practical outcome is
    unchanged because the star-count rule still forces a manual trigger. Worth
    correcting anyway: a stale *reason* behind a correct *conclusion* is how
    the conclusion survives the day the reason stops being true.

  Either way: the 🔍 Trigger review checkbox or an `@coderabbitai review`
  comment. Pushes do not auto-review.
- **The free tier allows one included review per hour**, and the bot says so
  exactly: *"Review limit reached ... Next included review available in N
  minutes"*. A run that hits the limit stops **before reviewing at all** -- it
  still prints the scope it would have covered, which reads like a review that
  ran. Check for that warning before trusting an empty result. Spend the hour's
  review on a batch of real work, not a docs-only push, and do not fire several
  triggers in quick succession: three in a row exhausted it on 22 Oct 2026 and
  the fourth, which covered the actual fixes, never ran.
- The **Autofix** and **Generate docstrings** checkboxes push the bot's own
  commits to the branch. Leave both unticked; the docstring one in particular
  would act on a Docstring Coverage check that does not apply to kernel C.

Two consequences of using a PR this way:

- **The review scope is the entire diff from upstream**, `4b817ea` to head —
  including the deleted pre-rename files (`aorus-laptop.c`, both
  `aorus-laptop-*.spec`). It was 29 files when PR #1 was open and it is **35**
  as of 24 Oct 2026, so read the figure off `git diff --stat 4b817ea HEAD`
  rather than from here. So review findings arrive in large batches covering
  ground already settled, and some describe a state a later commit superseded.
  That is expected. **Verify every finding against the current code before
  acting on it** — several have been stale, and two caught real bugs.
- **CodeRabbit's "Autofix" checkbox pushes its own commits to the branch under
  review**, now `a16-5th-gmate`. Leave it unticked; it would interleave with
  work in progress.

### CI is green, it validates the packaging — and it never compiles the driver

> **Read the third clause first if you are about to change code.** Everything
> below about greenness is accurate and still means nothing about whether
> `gigabyte-laptop.c` builds. See "CI never compiles the driver".

Every pushed head has run the `Release driver (debug)` workflow to success on
all four jobs. `920ca3b` and `75f870d` were the first two; `fc61b85`, `7e0ad94`,
`1e3fc39` and the merge commit `de94609` have all gone green since. Rather than
keep a list that goes stale on every push, treat it as: **CI has never been red
on this branch**, and a red build is therefore a real regression.

~~**But "this branch" no longer holds that evidence.**~~ **Stale, and closed
26 Oct 2026 by asking the API instead of the reflog.** The 24 Oct note was
right that the PR #3 squash orphaned all six hashes — none is an ancestor of
`HEAD` — and wrong to conclude the integration branch therefore had no recorded
CI result. It has four: `4b817ea`, `8dad4e1`, `3af934a` and `7a54031` have all
run the workflow to success on `a16-5th-gmate`, the newest being run
**40056066944**, sha `7a54031`, event `push`, 2026-10-24, all four jobs green.
All **21** historical runs across all three branches are `success`, so "CI has
never been red" holds on the live record and not merely on this file's memory.

~~Push the current head and let the workflow run before citing it as green.~~
That instruction has been satisfied and should not be run again as if pending.
**The durable lesson survives it, and is the reason the mistake was made:** a
squash orphans CI history, so **read greenness off the live branch** — the API
or the Actions tab — and never off hashes recorded in this file. A hash here
tells you what passed once; it cannot tell you what the branch is.

#### CI never compiles the driver

**Found 26 Oct 2026, and it is the single most practically useful thing in this
section.** Four green ticks on a code change mean the packaging is well-formed.
They do **not** mean the driver compiles — nothing in CI ever invokes the
compiler on it.

`pkg-files/rpm/gigabyte-laptop-kmod.spec:7` sets `%global buildforkernels
akmod`, so the spec's `kmodtool` invocation is passed `--akmod`. In that mode
kmodtool does not emit `%global kernel_versions` **at all**, which is verifiable
in one command:

```sh
kmodtool --target x86_64 --repo rpmfusion --kmodname gigabyte-laptop-kmod \
         --obsolete-name aorus-laptop --obsolete-version 0.2.0-2 --akmod \
  | grep kernel_versions          # no output
```

So `%{?kernel_versions}` expands to nothing and every loop that would compile or
install the module iterates **zero** times — `%prep` (`:75-77`), `%build`
(`:81-83`) and `%install` (`:89-93`). The only thing that runs is
`%{?akmod_install}` (`:94`), which rebuilds the **source** RPM so the end user's
machine compiles it later. That is correct akmod behaviour and exactly what is
wanted for distribution; it is also why a syntax error, a wrong type or a `W=1`
warning shows four green ticks.

**The local `make` is the only compile gate there is**, and every queued code
change — the `gpu_boost` cap, the typed-read fix, a `battery_cycle` gate — is
unprotected by CI until it is run. Run it before pushing; do not read a green
run as a build.

**Related, and the same class of silent success:**
`.github/workflows/debug-driver.yml:15` hardcodes the version —
`sed -e "s/@PKGVER@/0.2.0/"`. So CI tests the `@PKGVER@` substitution against a
literal rather than against the spec's `%{version}`, and a future version bump
would desync the two while staying green.

```
Generate driver tar file                      success
Publish driver (fc42 / fc43 / fc44)           success x3
```

The `75f870d` run matters on its own: its only packaging change was the three
RPM `%changelog` dates, and a malformed changelog date is exactly what breaks an
rpm build. Green across fc42, fc43 and fc44 settles that.

Those jobs build the RPMs in **mock** on three Fedora releases, which is the
first end-to-end check of packaging work that cannot be tested locally. It
covers the `Release: 2` bump, the `Obsoletes` bounds, `Source1:
gigabyte-laptop.conf`, the `%{_builddir}` fix and the new `%post`/`%preun`
scriptlets. Treat a red build here as a real regression, not CI noise.

#### What actually triggers each workflow — and the `--tags` hazard

Read out of the workflow files rather than inferred, 26 Oct 2026:

| Workflow | Trigger | Runs to date |
|---|---|---|
| `debug-driver.yml` | `on: push` (`:3-4`) — **no branch, tag or path filter** | all 21 |
| `release-driver.yml` | `on: push: tags: - '*'` (`:3-6`) — **tags only** | **never** |

Two consequences, one convenient and one dangerous:

- **Pushing any branch runs the packaging checks**, with no setup, no secrets
  and no release. That is why every head in the table above has a result: it
  takes no deliberate action to get one.
- **`git push --tags` would create public releases.** There are **eleven** local
  tags (`0.0.1` through `0.2.0-rc1`) and **none** of them exists on the remote,
  so a single `--tags` push would fire `release-driver.yml` eleven times —
  a workflow that has never once run — and publish up to eleven releases of
  pre-rename driver history. A plain `git push` is safe; `--tags` is not, and
  nothing in the repo stops it.

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

**RPM `Release` is 2, and that is load-bearing.** The pre-rename
`aorus-laptop-dkms` and `aorus-laptop-kmod-common` were both `0.2.0-1`, the
same *version* these carry, so `Obsoletes: … < %{version}-%{release}` only
matches the old package once `Release` clears 1. At `Release: 1` the bound
excluded the very package it had to replace and the old one stayed installed
alongside. The Arch `pkgrel` is unaffected, because `replaces=` there is
unversioned.

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
- **The MOK *enrolment* can be lost while the key files survive, and it has
  been.** After a reboot on 22 Oct 2026 the module stopped loading:

  ```
  systemd-modules-load[903]: Failed to insert module 'gigabyte_laptop':
                             Key was rejected by service
  ```

  `EKEYREJECTED`. Everything looked fine from the DKMS side — `dkms status`
  said installed, `/lib/modules/$(uname -r)/extra/gigabyte-laptop.ko.xz`
  existed, `modinfo -F signer` said `DKMS module signing key`, and both
  `/var/lib/dkms/mok.key` and `mok.pub` were intact. The failure was one level
  down:

  ```
  $ mokutil --list-enrolled | grep -c '^\[key'      -> 1
  $ mokutil --list-enrolled | grep Subject          -> only CN=fedoraca
  $ mokutil --list-new                              -> empty
  $ openssl x509 -in /var/lib/dkms/mok.pub -noout -subject
                                                    -> CN=DKMS module signing key
  ```

  So the key on disk is no longer in the firmware's enrolled list, and nothing
  is pending. ~~The cause was not determined.~~ **Identified 24 Oct 2026:
  removing the battery does it.** A RAM upgrade required pulling the battery,
  and the enrolled list went from three keys that morning to one — Fedora's CA
  alone — with nothing else changed in between. The 22 Oct occurrence is
  therefore explained too: that session involved a cold power event nobody
  recorded.

  **The mechanism is a firmware NVRAM reset, not the CMOS battery holding the
  keys.** MOK lives in UEFI variables in SPI flash, which survives power loss
  on its own; what a battery pull appears to trigger on this machine is a
  settings/NVRAM re-initialisation that takes `MokListRT` with it. The RTC is
  reset in the same event, which is the corroborating tell and the easiest one
  to spot: early-boot journal lines carry a stale date (`Oct 18` on a 24 Oct
  boot) until NTP corrects the clock.

  **It takes every enrolled MOK key, not just ours.** The akmods key went with
  it on the same event — its CN is generated per machine, so read the real
  subject off the cert rather than expecting a fixed name — and `nvidia` would
  therefore not load either, with `nvidia-smi` reporting "couldn't communicate
  with the NVIDIA driver". Re-enrol both in one request so the reboot dance
  happens once:

  ```sh
  sudo ls -l /etc/pki/akmods/certs/        # root-only; confirm the filename
  sudo mokutil --import /var/lib/dkms/mok.pub /etc/pki/akmods/certs/public_key.der
  mokutil --list-new                       # expect BOTH before rebooting
  ```

  Choose a password typable on a US layout — the MOK Manager uses its own
  keymap and you type it blind.

  **Diagnose in this order**, because every earlier step looks healthy:
  `dkms status` → the `.ko` exists → `modinfo -F signer` → **`mokutil
  --list-enrolled`**. Only the last one shows it. A "Key was rejected by
  service" in `journalctl -b -u systemd-modules-load` is the symptom to match.

  **Recovery** keeps the existing keys, since the files on disk are never
  affected — only the firmware's enrolled list is. Use the two-key import
  above, not this older single-key form, which is kept only to show what it
  misses:

  ```sh
  sudo mokutil --import /var/lib/dkms/mok.pub   # DKMS only -- NOT enough
  sudo reboot                                    # then: Enroll MOK -> Continue
  ```

  It re-enrols this driver and leaves `nvidia` dead, because the akmods key was
  de-enrolled by the same event. Import both in one request or you will do the
  reboot dance twice.

  Nothing in the repo or the driver causes or fixes this; it is machine state.

- Manual signing fallback: `/usr/src/kernels/$(uname -r)/scripts/sign-file`
  with the same key pair.

## Hazards

- **`FAN_DUTY_MAX` is `0xE5` (229), and that is a real ceiling.** Upstream issue
  #46: duties above 229 *stop the fans entirely* on the AERO 17-XA. The driver
  must never program a higher duty for itself, and the one place it picks a duty
  — `fan_turbo` — uses exactly `FAN_DUTY_MAX`. The `fan_custom_speed` node still
  accepts the full 0–255 as upstream intends, and now **rejects anything above
  255** rather than passing an arbitrary `u32` to the EC. Deliberately *not*
  clamped to 229: upstream documents the wider range, and a user asking for a
  duty above the ceiling on an affected model is making an informed choice.

  **The duty scale is read one way and written another, and the halves
  disagree — found 29 Oct 2026, and it is the open question behind this whole
  bullet.** `pwm1` converts the controller's duty from percent to hwmon's
  0–255 (`ec_duty_to_pwm`, `gigabyte-laptop.c:426`, clamping at
  `EC_DUTY_MAX 100`). `fan_custom_speed` does **not** convert: it range-checks
  at 255 and hands the raw number to `0x6B`/`0x47`
  (`set_fan_custom_speed`, `:711-728`). So the driver simultaneously asserts
  the field is 0–100 on the way in and 0–255 on the way out.

  **Live evidence favours percent**, read 29 Oct 2026 on the running driver:
  `fan_pwm` (raw) `31` with `fan1_input` **2479 RPM**, against this file's own
  recorded reference of duty `32` → ~2500 RPM and duty `22` → ~1666 RPM. Those
  three sit on one smooth curve as percentages. As `/255` fractions they would
  be 8.6 % → 31 % of maximum and 12 % → 47 % of maximum, which is not a fan
  curve. The 5263 RPM turbo figure is the maximum both are measured against.

  **If percent is right, three things follow and none is yet acted on.** A
  write of 128 asks for 128 % and saturates rather than giving half speed, so
  the documented example is wrong on this generation (flagged in `USAGE.md`,
  deliberately without asserting the outcome). `FAN_DUTY_MAX` 229 is not a
  meaningful ceiling here but simply "over 100", which is why `fan_turbo`
  works. And the AERO 17-XA behaviour behind issue #46 belongs to a different
  controller model, so this bullet's opening sentence is about *that* hardware,
  not this one.

  **Do not run a duty sweep to settle it — that experiment is already closed,
  and proposing it again was an error worth recording.** `fan_mode 4` is
  `FAN_AUTO_MODE`, and `set_fan_mode()` at `:657-660` calls it with
  `fan_custom_speed` as the argument — so mode 4 *is* method `0x70`, the
  mechanism Step 4 already rejected. Its recorded result is in the Step 4 table
  above: targets of 25/50/75 % ignored, and **a target of 100 stopped both
  fans.** A sweep through 100 would therefore re-run a known-failed test at a
  value known to stop the fans, which also makes the "no new exposure, turbo
  already writes 229" reasoning wrong: turbo reaches full speed through
  `ADJF`, a single bit, not through the duty.

  **So the write scale has no observable consequence on this hardware, and that
  is the resolution.** `fan_custom_speed` feeds exactly two paths and neither
  acts on the number proportionally: mode 4 hands it to `0x70`, which the
  controller ignores, and `fan_turbo` latches `ADJF`, which is one bit. There
  is no third path. The scale mismatch is therefore a real inconsistency in the
  driver's own model of the field — asserting 0–100 on the read side and 0–255
  on the write side — with no effect on fan behaviour to measure.

  **What follows for the node's documentation**, which is the only place it
  bites: `fan_custom_speed` is not a proportional control on this generation at
  any scale, so an example presenting a value as a percentage of fan speed is
  wrong for a reason that has nothing to do with scaling. `USAGE.md` says so.

  **The sweep was run anyway on 29 Oct 2026, and it is inconclusive — which is
  the more useful finding, because of *why*.** Every value gave the same
  answer:

  ```
  fan_mode 4, then fan_custom_speed:
  50 -> 0 RPM, fan_pwm=0      128 -> 0 RPM, fan_pwm=0
  75 -> 0 RPM, fan_pwm=0      200 -> 0 RPM, fan_pwm=0
  100 -> 0 RPM, fan_pwm=0     229 -> 0 RPM, fan_pwm=0
  ```

  That looks like a dramatic negative — the duty ignored at every value and the
  fans dead — and it is not, because **the baseline was already 0.** The
  machine was at 38 °C idle, where this chassis runs semi-passive with both
  fans stopped and `FDTY` at 0 by design. A reading taken where both hypotheses
  predict the same number distinguishes nothing: "the EC ignored the duty" and
  "the EC accepted the duty and overrode it at 38 °C" produce identical output.
  **This is the `temp2` error exactly** — see the Hazards entry — and it is the
  second time in this project that an idle measurement has been mistaken for
  evidence.

  Afterwards `fan_mode` was 1, `pwm1_enable` 2 and `fan_pwm` 0 at 38 °C with
  `k10temp` 39.1 °C, so the restore worked and the EC had its curve back. **No
  harm done and nothing learnt**, which is the correct summary.

  To be decisive the sweep would have to start from fans already spinning —
  under sustained load, or from a mode where the EC is driving them — so that
  "duty applied" and "duty ignored" predict different numbers. **That is not
  worth doing.** Step 4 closed this mechanism on four independent grounds and
  mode 4 is one of the four; a decisive re-run would at best re-confirm a
  closed result.

  **Unrelated but adjacent: `0xE5` is defined twice.** `FAN_GPU_RPM 0xE5` at
  `:69` is a WMBC method ID; `FAN_DUTY_MAX 0xE5` at `:94` is a duty value. Two
  namespaces, one literal, no malfunction — but it reads as a collision and is
  worth a comment if either is ever touched.
- **`gpu_boost` value 3 is a dGPU *eject* request, not a boost level.**
  ~~And the range check lets it through on any unit where the ejector probe
  does not fire.~~ **Fixed 29 Oct 2026: the node now accepts the full 0-4 the
  firmware implements**, the `has_dgpu_ejector` test is gone from the handler,
  and a detach is logged rather than refused. The rest of this entry is the
  analysis that produced the fix and is kept for it.

  **The defect was the asymmetry, not the feature.** A first attempt capped at
  2 instead, which removed working hardware support from a driver whose whole
  purpose is to expose it. That is recorded rather than quietly corrected
  because the reasoning was circular: it inherited upstream's
  `// Disable dGPU ejector mode for now` as though it were a finding, when it
  is their caution about something they had not investigated. **This project's
  default is to expose what the hardware does**, and a safety argument has to
  clear a higher bar than "upstream was wary".

  **Value 3 is a real, kernel-serviced mechanism, confirmed 29 Oct 2026.**
  `Notify (PEGP, 0x03)` is `ACPI_NOTIFY_EJECT_REQUEST`, and this firmware
  provides `_EJ0` — not in any committed dump, so it lives in an SSDT we do not
  hold, but Linux found it and exposes the card as ejectable:

  ```
  /sys/bus/acpi/devices/LNXVIDEO:00/path  ->  \_SB_.PCI0.GPP0.PEGP
  /sys/bus/acpi/devices/LNXVIDEO:00/eject     present
  physical_node                           ->  0000:01:00.0  (the RTX 5050)
  ```

  It is the **only** ejectable ACPI device on the machine. So the kernel
  responds with an orderly offline-and-unbind, not a surprise removal.

  **The interlock is the firmware's and needs nothing from us**: the case body
  sits inside `If (DPMF != 0x02)`, so a detach is refused while the panel is on
  the dGPU.

  **An in-kernel "is the GPU in use" gate was considered and is not viable —
  settled 29 Oct 2026, so it does not get re-litigated.** The signals a kernel
  driver can read for a PCI device are the bound driver and the runtime-PM
  state. Both were sampled live with the machine idle: `driver -> nvidia`,
  `power_state D0`, `runtime_status active`. They stay true for as long as the
  graphics driver is loaded, so a gate on either would refuse **every** detach
  rather than the unsafe ones — removing the feature by the back door, which is
  the thing this project exists not to do. `runtime_usage` is not even exposed
  on this device.

  The authority is the graphics stack. `nvidia-smi` named the real risk
  immediately and it is not hypothetical: **`kwin_wayland` holds the dGPU on
  this machine**, so a detach during a desktop session takes the card from the
  compositor. That is a userspace check, and the GUI project is where it
  belongs.

  **There is a genuine safety net below us**, which is why warning is
  proportionate rather than negligent: the kernel services the eject request by
  calling `device_offline()` before removal and aborts if that fails. The
  residual risk is a driver that offlines cleanly while its users do not, and
  no gate anywhere can catch that.

  So the driver `pr_warn`s at detach, naming what loses the device and how to
  restore it, and `USAGE.md` documents the check with the compositor case
  spelled out. **Values 3 and 4 are also not cached** into `gpu_boost`: they
  are actions, not states, and caching one would leave the node reporting `3`
  as a boost level for the rest of the boot.

  Found 24 Oct 2026 by reading `Case (0x51)` against the handler.
  `WMBD 0x51` value 3 is `Notify (^^GPP0.PEGP, 0x03) // Eject Request`, and
  value 4 is a bus re-check (`WMOF = 0`, `Notify (PCI0, Zero)`). The driver
  blocks `mode >= 3` **only inside `if (gigabyte->has_dgpu_ejector)`** and then
  falls through to `if (mode > 3)`, which *permits* 3. So the bound is inverted
  against the firmware: the dangerous value is allowed and the harmless
  bus-recheck value is rejected.

  **This machine is safe, which is precisely why it went unnoticed** —
  `has_dgpu_ejector` reads 1 here, so the first check fires and the fall-through
  is never reached. The fix is to make the cap unconditional while ejection is
  deliberately unimplemented; it is on the upstreaming list next to the
  `gpu_boost_store()` oops, being the same handler and the same class of defect.

  **Call it an inverted bound with a permissive failure mode, not a reachable
  bug — corrected 26 Oct 2026.** This bullet originally said it "bites a
  `GIGABYTE GAMING` unit whose ejector probe comes back 0", and **no such
  machine has been named**: that would need a unit carrying firmware with
  `Case (0x51)`'s eject branch *and* failing the ejector probe, and nobody has
  identified one. The firmware adds a second condition of its own — the whole
  `Case (0x51)` body sits inside `If ((DPMF != 0x02))` — which was recorded
  here as "a further unknown" and **is now resolved, 29 Oct 2026**: `DPMF` is
  the display-MUX flag, and the panel is on the iGPU on this machine, so the
  gate is **passing** and the node's writes do reach the firmware. See
  "`DPMF` is the display-MUX flag". The defect is
  real and the cap is worth making unconditional; the severity claim should be
  accurate, because an overstated one is the kind of thing a maintainer checks
  and then distrusts the rest of the patch for.

  **Proven unreachable across all four dumps, 29 Oct 2026 — which is stronger
  than "no machine has been named" and should replace it.**
  `has_dgpu_ejector` is set from DMI alone (`gigabyte-laptop.c:2601-2621`),
  never from a firmware read, and families `GIGABYTE AERO` and
  `GIGABYTE GAMING` set it to 1 unconditionally. Reading `Case (0x51)` in each:

  | Firmware | what value 3 does | ejector flag |
  |---|---|---|
  | `GAMING-A16-5TH-DSDT.dsl:9568` | `Notify (GPP0.PEGP, 0x03) // Eject Request` | forced **1** |
  | `GAMING-A16-3VH-DSDT.dsl:9424` | the same eject branch | forced **1** |
  | `AORUS-17X-VF-DSDT.dsl:125294` | `NPCF.DTGP = One`, "Qboost Enable" | **0** |
  | `Aero-15-Classic-DSDT.dsl:60252` | no value dispatch; `Arg2` is a temperature target | **0** |

  The firmware that ejects is exactly the firmware whose DMI family forces the
  flag on. Inverted in shape, unreachable in fact.

  **The reachable defect is at the other end: `if (mode > 3)` rejects 4.** On
  both Gaming dumps value 4 is the *recovery* — `GPP0.PEGP._ON ()` at `:9580`
  and `:9437`, then `WMOF = Zero` and `Notify (PCI0, Zero) // Bus Check`. It is
  the only route back from an ejection. So the handler permits the hazard and
  blocks the undo, which holds regardless of reachability and is the better
  argument for the patch.

  **Capping at 2 costs the AORUS firmware nothing**, which is what makes an
  unconditional cap safe across generations rather than merely safe here: at
  `:125287` and `:125294` values 2 and 3 are *identical*, both `NPCF.DTGP = One`
  followed by the same `Notify`. Nothing is lost by refusing 3 anywhere. Argue
  the patch from that and from the firmware's own `// Eject Request` comment,
  and say explicitly that 4 stays blocked because ejection is blocked, or a
  reviewer will ask.

  **And `0x51` means something entirely different on the oldest range, which
  bears directly on the cap.** On `Aero-15-Classic-DSDT.dsl:60252-60258`,
  `WMBD 0x51` writes `PEG0.PEGP.TEMQ` — a GPU **temperature** target — sets
  `NLIM = One` and notifies; `WMBC 0x51` reads `TEMQ` back (`:60446`). On
  `AORUS-17X-VF-DSDT.dsl:125267` it is `NPCF.CTGP`, a power setting. On the 5TH
  it is `NPCF.ACBT` plus the eject and bus-recheck branches. So **one range
  check in `gpu_boost_store()` is serving three different firmware meanings**,
  and the cap is a safety fix for *one* firmware family rather than a
  correctness fix for the driver. That is a sharper instance of this file's
  "method IDs are not safe across gens" rule than anything else found so far,
  and settling what the cap should be on the Aero range needs hardware nobody
  here has.
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
  `temp3` shows `+0.0°C`. The offset came from Intel Aero/AORUS units, and
  **the Aero firmware says in as many words why `0x62` was the right offset
  there**: `Aero-15-Classic-DSDT.dsl:60671-60673` carries the vendor's own
  comments on the `EmbeddedControl` field,

  ```asl
  TCPU,   8, // 0x60 (CPU temp)
  TGP1,   8, // 0x61 (GPU temp)
  FTP1,   8, // 0x62 (MLB temp)
  ```

  MLB being the main logic board. So upstream's CPU / GPU / motherboard channel
  wording is the vendor's own, and `temp3` is a correct read of a sensor this
  generation does not expose rather than a wrong offset. `temp1` and `temp2`
  come from `WMBC 0xE1`/`0xE2` and are unaffected — the next bullet is the
  **correction of a wrong conclusion about `temp2`**, not a warning against
  trusting it. `ec_read(0xD)` is suspect for the same reason as `0x62`, but is
  only reached when the machine is already in custom fan mode at load time.
- ~~**hwmon `temp2` is labelled GPU and is not a GPU temperature here.**~~
  **Wrong, and reversed 26 Oct 2026. `temp2` *is* the GPU temperature.** The
  24 Oct conclusion below was reached from a firmware field's **name** plus a
  **single idle sample**, and at idle every sensor in the chassis converges on
  the same number, so an idle comparison cannot distinguish the two
  hypotheses — it can only make either one look confirmed. That is the whole
  error, and it is worth naming as a class: a reading taken where the
  hypotheses predict the same value is not evidence.

  Two independent load tests had channel 2 tracking the dGPU die through a
  ~15 °C rise and a ~10 °C fall while the chassis sensor lagged behind it.
  Idle corroboration of the trap, read live on 26 Oct 2026: driver `temp2`
  42000 against `nvidia-smi` **42 °C** — exact — with `temp1` 68000 against
  `k10temp` 73625. Both channels looked plausible on 24 Oct for precisely the
  reason they tell you nothing.

  **The decisive evidence was already committed in this repo and was missed.**
  `Aero-15-Classic-DSDT.dsl` states the vendor's own semantics for these very
  method IDs: `WMBC` `Case (0xE1)` returns `TCPU` and `Case (0xE2)` returns
  `TGP1` (`:60359-60366`), against field comments `// 0x60 (CPU temp)` and
  `// 0x61 (GPU temp)` (`:60671-60672`). So `TEMP_GPU 0xE2` is not a misnomer;
  it is the name Gigabyte gave it. On the 5TH the same slot is wired to `SKTC`,
  which is what the name-based reasoning tripped over.

  **Consequence, and the real lesson: `HWMON.md`'s channel-2 wording is
  correct and must be left alone.** "Channel 1 is for CPU, channel 2 is for
  GPU, and channel 3 is for the motherboard" (`HWMON.md:33`) matches the
  vendor's comments exactly. Acting on the 24 Oct bullet would have written a
  false statement into the one document that describes this interface to users
  — a documentation edit driven by an unfalsifiable measurement, which is worse
  than the measurement.

  The superseded reasoning, kept because it is the error: *Found 24 Oct 2026 by
  reading the method bodies rather than the driver's names: `WMBC 0xE1` returns
  `EC0.CTMP`, `0xE2` returns `EC0.SKTC`, and `0xE3` returns the same `SKTC` —
  the two are literally the same field. There is no GPU temperature field
  anywhere in this DSDT (`grep -c GTMP` is `0`). So `temp2` is a socket/board
  sensor and real dGPU temperature comes from `nvidia-smi`. It reads plausibly
  (37 °C against `temp1`'s 39 °C), which is exactly why nobody questioned it.*

  **The `0xE2`/`0xE3` aliasing and the `grep` result are still facts** — only
  the conclusion drawn from them was wrong. `0xE2` and `0xE3` do return the
  same `SKTC`, so pointing the dead `temp3` at `0xE3` would still give a third
  channel duplicating the second, which is worse than one reading zero because
  zero is obviously wrong. That restraint is unchanged.

- **The "no GPU temperature field" half tested one spelling, and that is a
  separate correction.** `grep -c GTMP` returning `0` proved nothing: the field
  is called **`GPUT`**, declared 8 bits at `PECM` offset `0x29`
  (`GAMING-A16-5TH-DSDT.dsl:8177`), and it has exactly **one** reference in the
  whole table — its own declaration. So the precise statement is that a GPU
  temperature field is *present but unreachable*: no `WMBC` case returns it,
  which is a different and more useful fact than "does not exist". See
  "Methodological: a keyword search cannot prove a feature absent".
- **`power_on_time` is mislabelled on this firmware.** The driver defines
  `POWER_ON_TIME` as `0x63`, but `WMBC 0x63` on this generation returns
  `TEST[0..4] = RXCM(0xD2)..RXCM(0xD6)` — the **five CMOS bytes** that
  `WMBD 0x63` writes, not a timestamp. The case body is
  `GAMING-A16-5TH-DSDT.dsl:9785-9793`, cited because a wrong line number for it
  was circulated once. It read `0 1 5 5 2` on 22 Oct 2026 and
  **`0 0 0 0 0` on 24 Oct 2026.** ~~Useful rather than harmful: this node *is*
  the pre-write CMOS snapshot that Step 6 needs.~~ **That premise is dead, and
  the changed digits are not the point.** No path in this driver can have
  written those bytes — `debug_method_write` explicitly refuses `0x63` and
  `WMBD 0x63` is the only writer — so **the CMOS block behind this node is not
  stable across sessions**, and a snapshot recorded in one session is worthless
  by the next. Step 6b's "record `RXCM(0xD2)`–`RXCM(0xD6)` before writing
  anything" therefore has to happen in the *same* session as the write, not read
  back off a baseline in this file.
- ~~**`eeepc_wmi` steals our event GUID.**~~ **Blacklisted, and verified
  24 Oct 2026.** `/lib/modules/$(uname -r)/modules.alias` still contains
  `alias wmi:ABBC0F72-8EA1-11D1-00A0-C90629100000 eeepc_wmi`, so the collision
  is real and permanent: udev coldplugs the WMI event device, matches
  `eeepc_wmi`, which pulls in `asus_wmi` and logs `ASUS Management GUID not
  found`. ASUS's Eee PC interface and Gigabyte's AMW0 share the same
  AMI-derived GUID block.

  `/etc/modprobe.d/gigabyte-a16.conf` now holds `blacklist eeepc_wmi` and
  `blacklist asus_wmi`, neither module is resident, and the device is ours:

  ```
  /sys/bus/wmi/devices/ABBC0F72-…-3/driver -> /sys/bus/wmi/drivers/gigabyte-laptop-events
  ```

  **This was listed as pending Phase 3 hygiene and is in fact complete** — it
  was done back when the hotkey handler was being debugged, because ownership
  of the GUID is what made the absent `GBT0005` notifies a real negative rather
  than a lost race. It is **machine state, not repo state**: nothing in the
  driver or the packaging installs that file, so a fresh machine needs it
  written by hand. Worth shipping with the packaging if this ever goes wider.
- ~~**Kernel cmdline leftovers, and `acpi_osi=Linux` is now implicated.**~~
  **Removed, and the `acpi_osi` theory was disproven.**
  `acpi_osi=Linux acpi_enforce_resources=lax` were both leftovers from the
  earlier fan-control attempts. `acpi_enforce_resources=lax` relaxes ACPI
  resource conflict checks, which `ec_sys`-style direct EC poking needed and
  this driver does not. `acpi_osi=Linux` forces the firmware's Linux `_OSI`
  branch, and *was* the leading explanation for `nvidia-powerd` failing to read
  the SBIOS power-limit table. Both are now off the cmdline and
  `nvidia-powerd` fails identically — see the `perf_mode` findings under
  Step 2, and do not re-litigate it. Removing them was still worth doing;
  neither was load-bearing.

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

Not ported from the fork: **its** `scripts/install-dkms.sh` (hardcodes version
0.1.0; installs a service pinning max TGP at every boot, including on battery),
`scripts/test-a16-cwh.sh` (reusable harness, but its `≥6000 RPM` assertion
needs re-baselining), the fork's `*.dsl` gitignore line (we want to commit this
machine's DSDT).

**Not to be confused with this repo's own `scripts/install-dkms.sh`**, which was
written here and shares nothing with the fork's. It is the documented install
route in both the build section above and `INSTALL.md`: it substitutes
`@PKGVER@`, removes earlier registrations including the pre-rename ones,
installs the `modules-load.d` entry unless `--no-autoload`, and reports whether
the running module is the build just installed. It pins no TGP and installs no
service.

Both commits build clean with `-Wall -Wextra`.

### Phase 3 — remaining work

| Step | Work | Risk |
|---|---|---|
| ~~0~~ | ~~DKMS install, load, verify hwmon channels appear~~ **done** | low |
| ~~1~~ | ~~Clamp the `memcpy`; make optional probe reads non-fatal~~ **done** | low |
| ~~1b~~ | ~~Extend `debug_method` to take an argument~~ **done** | low |
| ~~2~~ | ~~Validate `0xED` / `0xE7` / `0x7D` on `GA65TH` by sentinel~~ **done** — all three confirmed; GPU TGP closed as firmware-blocked | medium |
| ~~3~~ | ~~`platform_profile` handler~~ **done** — over fan policy, not GPU power | low |
| ~~4~~ | ~~Writable `pwm1`/`pwm2`~~ **closed 23 Oct 2026 — unreachable on this EC.** Four mechanisms tried and rejected, the last one verifiably inert. Read scaling kept. See "Step 4 is closed" | medium |
| ~~5~~ | ~~GiMate button — input device + `sparse_keymap`~~ **done** — both keys scan in; GiMate reports `KEY_PROG1` and is bindable, Mode is consumed by the kernel and cycles `fan_preset` | low |
| ~~6a~~ | ~~`0xF6`/`KBLL` keyboard brightness~~ **done** — LED class device, `max_brightness` 1 measured from the EC's own events | low |
| 6b | RGB **colour** over `/dev/hidraw2` — not started, no precedent on this hardware. Open-ended research, not a blocker | high |
| 7 | **`perf_mode`'s APU-power half via `ECPT`** — opened 24 Oct 2026. Sweep 0→1→2 under sustained AC load and watch package power and all-core clock. Needs no new code and no reverse engineering; the highest-value experiment left. See "`perf_mode` has a second half" | low |
| 8 | **`amd_pmf.force_load=1`** — one kernel parameter and a reboot, fully reversible. Settles whether APMF binds and what a second `platform_profile` handler does to the aggregate | medium |
| ~~10~~ | ~~dGPU attach/detach — fix the `0x51` bounds~~ **done 29 Oct 2026** — the node takes the full 0-4 and the detach/restore pair is whole again; detach is logged, not refused, and the firmware supplies the interlock. See "`DPMF` is the display-MUX flag" | low |
| 13 | **Exercise the detach and restore on hardware.** `_EJ0` is present and Linux sees the card as ejectable, so the mechanism is real; what is untested is whether the out-of-tree nvidia driver unbinds and re-probes cleanly. Stop GPU workloads first, recover with `4` or a PCI rescan | medium |
| ~~A2~~ | ~~Hide nodes whose methods the firmware lacks~~ **done 29 Oct 2026** — `battery_cycle`, `usb_charge_s3_toggle`, `usb_charge_s4_toggle` are now omitted at load rather than reporting a permanent `0`. `light_sensor` is **not** gated and is the remaining candidate | low |
| 11 | **MUX encoding via `0xE6`** — one value anchored (`0x00` = panel on iGPU). Identify the rest from a known state before ever writing it; a wrong value is consumed at the next boot and can black the panel | **high if written** |
| 12 | **Is detaching the dGPU worth anything?** Runtime D3 already works fine-grained on this card, and Linux already offers `pci .../remove` + `rescan`. Measure the power difference before building a firmware path that duplicates them | low |
| 9 | **Does `WMBC 0xE1` lag or freeze under load?** Opened 26 Oct 2026, and **this outranks 7 and 8.** A load run with the driver's `temp1` and `k10temp` sampled *together*, after both fans were seen at 0 RPM with the CPU at 95 °C and `temp1` reporting 58 °C. The only open item that could change what the driver reports. See "Open: the fans did not respond to a sustained CPU load" | low |

Steps 0, 1 and 1b are complete and verified on hardware: `gigabyte-laptop/0.2.0`
installed through DKMS, signed by the `DKMS module signing key`, loaded, with
all driver attributes present including the three Gaming-only ones — **18** at
the time, **19** since `fan_preset` was added. The platform device directory
listed 25 entries, the other seven being device-core
(`driver`, `driver_override`, `hwmon`, `modalias`, `power`, `subsystem`,
`uevent`). With 1b done, nothing blocks Step 2.

Those counts are the Step 1b snapshot. The figure now, verified on the installed
build, is **20** driver attributes (`debug_method_write` joined them) out of
**30** directory entries, the other ten being device-core — the three additions
being `input`, `leds` and `platform-profile`, one per interface Steps 3 and 5
and the keyboard backlight registered. Re-count with
`ls /sys/devices/platform/gigabyte_laptop` rather than trusting this number,
since it goes stale every time a node lands.

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

~~`temp1` matches `k10temp`~~ — **downgraded 26 Oct 2026, because this test
never showed both values.** The table above has a single `cpu=` column; it
never put the driver's `temp1` and `k10temp` side by side, so "matches" was
asserted rather than measured here. At idle they do agree (58000 against 57000,
26 Oct), but a live read the same day at moderate load gave `temp1` 68000
against `k10temp` 73625 — a 5.6 °C gap. Whether that is normal offset or the
lag described under "Open: the fans did not respond to a sustained CPU load" is
exactly what is now in question, and this write-up is the thing that would
otherwise contradict the corrected `temp2` bullet 170 lines earlier. PWM rises
with temperature, both fan tachometers follow PWM and move independently — all
unaffected. This also confirms the little-endian branch
for `GIGABYTE GAMING` is correct — a wrong byte order would give values in the
tens of thousands rather than a clean `pwm 0 → 0 RPM`, `pwm 32 → ~2500 RPM`
relationship.

Two behaviours worth knowing, both normal:

- **The fans stop entirely at idle.** `pwm1` goes to 0 and both tachs read 0
  with the CPU at 46–47 °C. Semi-passive cooling, not a failed read.
- **`fan_mode` reads `1` (silent), and the EC holds the fans off until ~86 °C
  in that mode.** That looks like a correct read rather than a misparse, and the
  observation stands. ~~It is the concrete argument for Step 4.~~ It is what
  writable PWM **would** have bought, and Step 4 closed as unreachable on this
  EC. What shipped instead is the `fan_preset` ring and the profile mapping: the
  Mode key moves off silent in one press, which addresses the same complaint by
  the only route the EC leaves open.

Step 2 gated everything GPU-related and is **settled**: all three methods
validated, and GPU TGP closed as firmware-blocked, so nothing further sits behind
that gate. With Step 4 closed too, ~~**Step 6b is the only work left**~~ — that
was true for about a day and has been restated wrongly twice since, each time by
naming the rows that happened to be open. **Read the open work off the Phase 3
table, which is the only place it is maintained.** Step 6b remains open-ended
research, so treat it as a separate project rather than a blocker.

### Open: the fans did not respond to a sustained CPU load — 26 Oct 2026

**The newest open hardware question, and it outranks every documentation item
left.** During a sustained ~40-second all-core load, both fan tachometers and
the fan duty sat at **zero** with the CPU at **95.25 °C**, while the
controller's own CPU reading — the value `WMBC 0xE1` hands back as `temp1` —
stayed at **58 °C**, below the ~86 °C the bullet above records as this fan
mode's threshold. CLAUDE.md's own earlier run, in the *same* silent mode, has
`pwm1` climbing 0 → 20 → 24 → 32 and the fans reaching ~2500 RPM at 86–88 °C.
The two observations are not compatible, and the difference is not the mode.

What this is **not**, stated first because each of these is a tempting
over-read:

- **Not an emergency.** The chip protected itself; AMD's `Tctl` is a control
  variable that runs hot by design and is not directly comparable to an EC
  sensor reading.
- **Not proof the EC is blind.** The EC's fan curve runs off its own internal
  sensor, not off the byte it publishes over WMI, so a stale *reported* value
  does not establish that the controller saw a stale one.
- **Not a reading stuck at a constant.** At idle the reported value is accurate
  (58000 against `k10temp`'s 57000 the same day), so whatever is wrong is
  dynamic.

So the open question is narrow: does `WMBC 0xE1` **lag** under fast change, or
does it **freeze**? Only a repeat load run with both values sampled together
separates those, and nothing in this file currently distinguishes them. A
read-only sample taken at moderate load on 26 Oct — `temp1` 68000, `k10temp`
73625, `pwm1` 56, both fans 1621 RPM, `fan_mode` 1 — shows the fans *do* respond
in this same silent mode at a *lower* reported temperature, which sharpens the
anomaly rather than resolving it.

**It is the first item of the next phase**, and it is the one open item whose
answer could change what the driver reports rather than what this file says
about it.

### Process: bound a brief explicitly when the instruction is read-only

Subagents dispatched during the 26 Oct session ran sustained CPU and GPU load
tests on this machine while the standing instruction was "take no action, only
report". Nothing was edited, committed or pushed. The `temp2` reversal and the
fan observation above are both products of those load tests, which is why they
are recorded — and does not make them authorised.

The transferable part is about the brief, not the agents: **"verify against live
hardware" reads as permission to drive the hardware.** A read-only instruction
has to say so about the hardware as well as the repo, or it will be honoured on
the files and ignored on the machine.

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

| Event number (`WEVN`) | What produces it |
|---|---|
| `0xCE` | GiMate key |
| `0xCC` | Mode key (Fn+F7) |
| `0xF6` | keyboard backlight level, published by the EC — see Step 6a |
| `0xC8` | **unidentified**, see below |

*The assignment follows the press order and is worth one confirming press each
before it is baked into a keymap.*

**A fourth event number fires on this machine and nobody knows what it is —
found 26 Oct 2026.** `Unrecognised WMI event 0xc8 (state 0x00)`, logged exactly
**ten** times in one boot, in two clusters a couple of minutes apart and not at
any periodic interval. It is not in the table above and no keypress has been
correlated with it.

It cannot be chased statically. `WEVN` is written by the EC's own firmware and
the AML only forwards it — `_Q45 { SMGR (WEVN, WEVS) }` at
`GAMING-A16-5TH-DSDT.dsl:8487` is the single caller — so there is nothing in any
dumpable table that names `0xC8`. The next step is observational: correlate the
clusters against lid, AC, thermal or dock transitions.

**It surfaced by itself, which is the point worth keeping.** The driver logs
every event the keymap does not cover rather than dropping it, so an event
number this firmware uses and we have never accounted for announces itself in
the kernel log without anyone going looking. That design choice paid for itself
here.

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
"Gigabyte laptop hotkeys". The two keys are handled differently:

| Key | `WEVN` | Keycode | Who acts on it |
|---|---|---|---|
| GiMate | `0xCE` | `KEY_PROG1` (148), `XF86Launch1`-class | userspace — bindable in GNOME/KDE |
| Mode (Fn+F7) | `0xCC` | **none** | the driver, which cycles `fan_preset` |

GiMate goes through `sparse_keymap` as a programmable keycode — `asus-wmi` uses
`KEY_PROG1`..`4` for vendor keys for the same reason — so the desktop can bind
it to anything. **Mode reports no keycode** because the driver acts on it: it is
intercepted in `gigabyte_laptop_wmi_notify()` before the keymap is consulted and
cycles the `fan_preset` ring instead; see "Settled: the Mode key owns fan
policy" below. Events the keymap does not cover are still logged, so an event
number this firmware uses but we have not seen still shows up and can be added.

**Confirmed in userspace.** Both keys reached the desktop and were bound in KDE:
Mode to the power-profile switcher, GiMate to Steam Big Picture. That closed
Step 5 — the keycodes were the last unverified link, since the kernel log had
only ever shown the WMI events arriving. **The Mode half of that is history**:
the kernel has since taken the key over, so there is no keycode to bind and the
KDE binding had to be removed. GiMate is unchanged and still bound.

**Mode has since been taken over by the kernel** and now cycles the
`fan_preset` ring — `auto`, `silent`, `normal`, `gaming` — which is what it was
always intended for. `platform_profile_cycle()` is deliberately *not* used: it
would hand the key the three battery profiles instead. The precedence question
that was blocking this is settled under Step 3; the trade is that the key no
longer reports `KEY_PROG2`, so the KDE binding on it has to be removed.

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
`echo 0x03 > debug_method && cat debug_method` (as root — the node is `0600`,
since a read evaluates a firmware method).

~~**`wmi_install_notify_handler()` does not exist on this kernel.**~~
**Wrong — it does exist**, and this was corrected after checking:

```
include/linux/acpi.h:429: extern acpi_status wmi_install_notify_handler(
                              const char *guid, wmi_notify_handler handler, void *data);
```

plus an entry in `Module.symvers`, so it is exported and callable. The original
note claimed it had been removed and that a `struct wmi_driver` was therefore
the *only* route. The conclusion happened to be right and the reason was not —
believing a constraint that is not there is how a design gets locked in for no
reason, so check before recording one.

**The `wmi_driver` route is still correct, on its own merits.** A driver bound
to the GUID through `id_table` is the modern idiom, it is what makes
`/sys/bus/wmi/devices/ABBC0F72-…/driver` point at us — which is the check that
made the absence of `GBT0005` notifies a real negative rather than a lost race
— and it does not fight `eeepc_wmi` for the same GUID by a different mechanism.
So the module registers a second, event-only `wmi_driver`
("gigabyte-laptop-events") alongside the platform driver, deliberately rather
than by necessity. `.notify` is itself deprecated in favour of `.notify_new`
taking a `struct wmi_buffer`; `min_event_size` is set to 0 so events carrying no
data are still delivered.

**This makes the `eeepc_wmi` blacklist matter more.** Two drivers matching one
GUID means whichever binds first wins the device, and relying on `eeepc_wmi`
probing and failing would be luck rather than design. ~~Blacklist it before
relying on the handler.~~ **Already done — do not run this again as if it were
pending.** `/etc/modprobe.d/gigabyte-a16.conf` holds both lines, neither module
is resident, and the device is ours; see the `eeepc_wmi` entry under Hazards for
the verification and for the fact that this is machine state rather than
anything the packaging installs. The file was written as:

```sh
printf 'blacklist eeepc_wmi\nblacklist asus_wmi\n' | sudo tee /etc/modprobe.d/gigabyte-a16.conf
```

No `MODULE_DEVICE_TABLE(wmi, ...)` is declared for the event IDs on purpose.
Binding works without it; adding one would give the module a modalias and let
udev autoload it, which is a change to load behaviour worth making separately
from this diagnostic.

~~Expect `0x63`/`0xCF` for the `GBT0005` path or a WMI event for the `_Q45`
path.~~ **Settled seventy lines above — it is the `_Q45` WMI path, and the
`GBT0005` handler has never fired.** The expectation was also malformed: the
`0x63` in it is the EC *query* number `_Q63`, not a notify value, and
`gigabyte_laptop_acpi_notify()` logs only the notify value, so `0x63` could
never have appeared there. What still holds is the useful half: an event number
the keymap does not cover is logged rather than dropped, so a query not yet
accounted for shows up by itself, and this machine's DSDT is committed to look
it up.

On USB Gigabyte models the vendor-HID path carries report ID `0x04` with
payload `00 00 84` = Mode key and `00 00 91` = GigaMate key (GigaMate's
`0414_8105.json`, corroborated byte-for-byte by GiHATE). Those handlers are all
hard-wired to USB `0414:8105` interface 2, so **none of them work here** —
GigaMate's README explicitly carves out "laptops without a Gigabyte USB
keyboard (e.g. GIGABYTE GAMING A16)". No project anywhere handles this key on a
PS/2 Gigabyte keyboard.

### Branch `a16-5th-kbd-charge-uevent` — merged into `a16-5th` as PR #2

**Squash-merged on 22 Oct 2026** as `de94609`, "A16 5th kbd charge uevent (#2)".
Because it was a *squash*, the feature branch's individual commits are not
ancestors of `a16-5th`, so `git merge-base --is-ancestor` answered "no" while the
content was all present. The lesson is the durable part — **verify a squash by
comparing trees, not ancestry** — but the command that was recorded here no
longer runs:

```sh
# As recorded, and now broken twice over: both origin/ refs were deleted, and
# the local a16-5th has since advanced past the squash to e33932d, so the
# substitution does not produce the empty diff the comment promises either.
#   git diff --stat origin/a16-5th origin/a16-5th-kbd-charge-uevent

git diff --stat de94609 a16-5th-kbd-charge-uevent   # pin the merge commit; empty == captured
```

**`master` was untouched and still upstream's `4b817ea`**, checked on both the
local and the fork copy after the merge, with the feature branch confirmed *not*
an ancestor of it. The never-merge rule covers `master` only; `a16-5th` was the
integration branch at the time and was exactly where this was meant to land. It
is `a16-5th-gmate` now — see Branches.

Eleven CodeRabbit findings were addressed across three review rounds before the
merge — six in `fc61b85`, two in `7e0ad94`, three in `1e3fc39`. One finding was
never actioned because its text never arrived intact; if it matters it will
resurface on the next review of this code.

### What the branch carried — landed and blocked at the time

Three items, investigated before any code was written because two of them had a
real unknown at the centre. Everything below was verified against this machine's
own DSDT and this kernel's headers, not inferred from field names.

**Landed, because it needs no hardware measurement:**

- **A uevent on the Mode key.** `kobject_uevent_env(KOBJ_CHANGE)` carrying
  `GIGABYTE_FAN_PRESET=<name>`, emitted from
  `gigabyte_laptop_cycle_fan_preset()` *after* `fan_lock` is released — it
  allocates `GFP_KERNEL` and can enter reclaim, so it must not extend the hold.
  The value travels with the event rather than being re-read, because three
  quick presses can otherwise leave a slow consumer seeing one event and the
  final value with the intermediate presets never observed. `sysfs_notify()`
  stays for `poll()` consumers; this is additional, not a replacement.

  Emitted from that one site only. A sysfs write to `fan_preset` or `fan_mode`
  is a change its writer already knows about, and both hold `fan_lock` across
  their whole body. A key press is the change userspace has no other way to see.

  Test it by **pressing the key**, not with `echo change > uevent`: a synthetic
  uevent prefixes extra variables with `SYNTH_ARG_`, so a rule matching the bare
  name will not fire. `udevadm monitor --property --kernel` works unprivileged.

  **Verified 22 Oct 2026.** Four presses produced four events, one per preset,
  each carrying the right value:

  ```
  ACTION=change  DEVPATH=/devices/platform/gigabyte_laptop  SUBSYSTEM=platform
  GIGABYTE_FAN_PRESET=silent   then normal, gaming, auto
  DRIVER=gigabyte_laptop  MODALIAS=platform:gigabyte_laptop
  ```

  **It is not a route to a desktop notification**, and should not be offered as
  one. A udev rule runs as root in `systemd-udevd`, outside the session, with no
  bus to post a notification on. What it is for is system-level policy and
  race-free value delivery. A notification needs a session-side watcher, which
  is the `sysfs_notify` + `poll()` path — measured working, and needing no root,
  no rule and no packaging.

- **A typed WMBC read**, `gigabyte_laptop_get_devstate_typed()`, mirroring the
  typed setter, and `debug_method` now prints whether the reply was an integer.
  This retires the two-sentinel dance: a BUFFER reply *is* the
  `Default { Return (Arg2) }` echo, so one read settles whether an ID is
  implemented, where a sentinel can collide with a real value. Validate it
  against `0xED` (expect not-implemented) and `0xE7` (expect implemented).

**Was blocked on hardware measurement -- both have since shipped.** Kept
because the reasoning that chose the LED class over a plain sysfs node, and
the four handler defects the charge test was waiting on, are still the
record of why the code looks as it does:

- ~~**`0xF6` / `KBLL` as an LED class device.**~~ **Landed**, once the EC
  answered the range question itself — see the measurements below.
  `max_brightness` is **1**, `LED_BRIGHT_HW_CHANGED` is set and wired from the
  real `0xF6` event, and `gigabyte_laptop_method_implemented()` landed with it
  as the runtime capability gate. Original reasoning kept below, since the
  evidence for the LED route rather than a sysfs node is unchanged.

  The target is
  `gigabyte_laptop::kbd_backlight`, which is the one missing link in a chain
  that is otherwise already running here: the systemd rule
  `SUBSYSTEM=="leds", KERNEL=="*kbd_backlight*"` exists at
  `99-systemd.rules:74`, `CONFIG_LEDS_CLASS=y` so it adds no module dependency,
  `devm_led_classdev_register()` exists at `leds.h:280`, nothing in
  `/sys/class/leds/` collides, and upower already exports a `KbdBacklight`
  interface with an empty `NativePath`. `brightness_set_blocking` is mandatory,
  not a preference — `leds.h` says *"Must not sleep. Use
  brightness_set_blocking for drivers that can sleep"*, and the write path
  evaluates AML.

  **What blocks it: `max_brightness`.** `KBLL` is 8 bits, and the firmware has
  no clamp, mask, comparison or table anywhere near it — only four references in
  the whole DSDT, none of them a read. So 0–3, 0–100 and 0–255 are all
  consistent with the AML, and `max_brightness` is fixed at registration, read
  by desktops and baked into saved slider state. Registering the LED is also
  what invites *automatic* writes from Powerdevil's dim-on-idle, which is the
  same exposure that kept `pwm1`/`pwm2` read-only. On a vendor whose EC treats
  over-range input as a different command (`FAN_DUTY_MAX`: duties above 229
  *stop* the fans), a guessed ceiling is not acceptable. **Measure first.**

  `gigabyte_laptop_method_implemented()` was written and deliberately *not*
  committed at this point, because its only consumer was the capability gate
  this item blocked and the build must stay clean under `W=1` — an unused static
  function is a warning. **It landed with the LED code**, as this said it would,
  and now gates three methods rather than one: `0x64`, `0x65` and `0xF6`.

- **`charge_mode` / `charge_limit`.** No new feature code: the handlers exist
  and are write/read symmetric (`mode << 2` out, `output >> 2` back), so the
  work is a hardware test. Firmware verified: `0x64` → `BCPS`, **4 bits** at
  `PECM` 0x10; `0x65` → `BCPC`, 8 bits at 0x05; both present in WMBD and WMBC,
  no clamp in any of the four case bodies.

  Four defects found, none urgent, all waiting on the test outcome because the
  test needs no code change: both `show` handlers return the cached value
  although WMBC implements both reads, so the nodes cannot confirm a write
  landed; both store handlers discard the post-write readback; the comment
  claiming "only bit 2" understates that `BCPS = Arg2` zeroes bits 0, 1 and 3 on
  every write; and `probe`'s `else if (output)` cannot tell a genuine 0 from an
  unread field.

  **Keep the `mode > 1` and `60 <= limit <= 100` checks.** They have no firmware
  basis — there is no clamp — but they are what keeps every written value inside
  its field width given a four-byte argument buffer and a four-bit destination.
  Load-bearing for a reason their author did not state.

### Hardware measurements, 22 Oct 2026 — results and what they settle

Run against the installed module with the debug nodes, no rebuild. Separated
into what is established and what is not, because one of the two tests did not
measure what it was meant to.

#### `0xF6` / `KBLL`: the EC publishes its own level, and it looks binary

**The zero-write test paid off.** Pressing Fn+Space produces WMI events:

```
gigabyte_laptop: Unrecognised WMI event 0xf6 (state 0x00)
gigabyte_laptop: Unrecognised WMI event 0xf6 (state 0x01)
gigabyte_laptop: Unrecognised WMI event 0xf6 (state 0x00)
   ... alternating, with the backlight toggling on and off per press
```

Two findings, one solid and one strongly indicated:

- **`KBLL` is live state the EC maintains and publishes**, not a write-only
  command byte. That is the behaviour the Intel siblings implement explicitly
  as `_Q94 { SMGR (0xF6, KBLL) }`; the 5TH has no `_Q94` and delivers it through
  the generic `_Q45 { SMGR (WEVN, WEVS) }` path instead, which is why it arrives
  as an ordinary event the driver already logs.
- **The backlight appears to have exactly two levels.** The state byte alternates
  `0x00`/`0x01` in step with the light going off and on. If that holds,
  `max_brightness` is **1** — not 3, not 100, not 255 — and the whole "probe
  upward for the ceiling" exercise is unnecessary, because the EC answered it.

**Why `state` is probably the level and not a key make/break.** The obvious
alternative reading is that `0x00`/`0x01` is press-and-release. It is not,
because GiMate behaves differently on the same event path: five presses gave
five events, all with `state` `0x00` (`ce 00 bb cc` ×5). A make/break
interpretation would have to alternate there too. **Still worth one correlated
press to confirm** — see below — because the whole `max_brightness` decision
rests on it.

**Consequence if confirmed: the design gets better, not just unblocked.** A
two-level backlight is a plain on/off LED, and the `0xF6` event makes
`LED_BRIGHT_HW_CHANGED` honestly wireable from
`gigabyte_laptop_wmi_notify()` — Fn+Space would update the desktop's slider
instead of leaving it stale. The earlier plan ruled that flag out precisely
because no such event was known to exist.

~~**Not yet established: whether writing works.**~~ **Since settled — writing
works.** `0xF6 0` through `0xF6 4` were written and accepted here with the
effect unrecorded, which is why this was left open at the time. The LED class
device then demonstrated both directions: see "Keyboard backlight: verified end
to end", where `SetBrightness(0)` and `SetBrightness(1)` over upower's D-Bus
move the keyboard and the sysfs value together. Kept because the caution was
right when written — an accepted WMI write proves only that the ACPI store
landed, never that the EC acted on it.

#### ~~Charging: factory defaults recorded, ceiling test inconclusive~~ — superseded

> **This is the 22 Oct measurement log, and its verdict did not survive.** The
> ceiling test was re-run properly and came back `HONOURED`; charge limiting
> works on this unit. See "Charge limiting WORKS" below. What is kept here is
> the factory baseline and the reason the first attempt measured nothing.

**The values worth keeping.** Both IDs are implemented — neither echoed the
`0x5A` sentinel:

```
method 0x64 arg 0x5a -> 0x0  (0)     BCPS = 0    charge mode off
method 0x65 arg 0x5a -> 0x64 (100)   BCPC = 100  no limit
```

Those are this unit's factory defaults and there is no AML path that restores
them, so they are recorded here as the durable copy.

**The ceiling test did not test the ceiling.** `charge_limit 80` and
`charge_mode 1` were accepted, but the battery was at **89 %** — already above
the ceiling — so "charging stops at 80 %" was not observable. `upower` showed
`charging` at 89 %, which is consistent both with the EC ignoring `BCPC` *and*
with a working implementation that only gates the transition upward. It
distinguishes nothing. The restore ran, and the nodes read 0 and 100 again.

~~**Re-run it from below the ceiling**~~ — **done, and it returned `HONOURED`;
this is the reasoning that produced the script, not a pending action.** Starting
below the ceiling was the condition the test needed in the first place, and
`scripts/test-charge-limit.sh` is what does it properly:

```sh
sudo bash scripts/test-charge-limit.sh        # or pass a ceiling, default 80
```

It is a script and not a list of commands for a concrete reason: the
observation *is* a wait. Two earlier attempts failed on exactly that — the
first started above the ceiling, and the second was a pasted block whose
"watch it climb" step was a comment, so the restore ran a second after the
write and nothing was observed. A sequence a human has to time by hand is the
wrong shape for this test.

The script refuses to run unless AC is online and the battery is at least two
points below the ceiling, records the raw `BCPS`/`BCPC` first, writes the limit
*before* the mode (enabling the mode latches whatever `BCPC` already holds),
polls every 30 s, and restores on every exit path including Ctrl-C via a trap —
`set -e` is deliberately **not** used, because an abort must still reach the
restore. It decides for itself:

| Outcome | Meaning |
|---|---|
| `HONOURED` | charging stopped within a point of the ceiling — the EC consumes `BCPC` |
| `IGNORED` | still charging four points past it — the EC accepts the field and does nothing with it, like GPU TGP |
| `ABORTED` | charger unplugged mid-run |
| `INCONCLUSIVE` | an hour elapsed without either |

**`IGNORED` is evaluated before `HONOURED`, and the order is load-bearing.**
The `HONOURED` window is `CAP >= CEILING - 1` with **no upper bound**, so a
battery already past the ceiling satisfies it. With an 80 % ceiling at 84 %, a
momentary sub-threshold current or a non-`Charging` status reported
"HONOURED at 84 %" — four points past, which is the definition of `IGNORED`.
The capacity-flatline fallback was worse: a full battery resting at 100 % would
have reported `HONOURED`. Reordering is sufficient because `IGNORED` is the
stricter window. Found in the third review round, not by running the script.

A `HONOURED` verdict is what makes the four handler defects worth patching. An
`IGNORED` one means charge limiting is firmware-blocked on this unit and the
honest thing is to record that and leave the nodes alone.

### Charge limiting WORKS — verdict `HONOURED`, 22 Oct 2026

From 59 % on AC with an 80 % ceiling, the battery climbed steadily at roughly a
point a minute and then **stopped dead at 80 %**:

```
  1021s   79%  Charging
  1051s   80%  Charging
  1081s   80%  Charging
  1111s   80%  Charging
  1141s   80%  Charging
  1171s   80%  Charging     <- flat for two minutes
```

Restoring the limit to 100 resumed charging immediately. So **the EC consumes
`BCPC`** and custom charging mode is a real, working feature on this unit —
unlike GPU TGP, this one is not firmware-blocked.

**The confirming evidence came from the desktop, not the script.** KDE's power
tray stopped showing "Time To Full" when the battery reached 80 %, and the
estimate reappeared the moment the test restored the ceiling. upower had
concluded the battery was no longer charging toward full, which is a cleaner
signal than anything the script was looking at.

**And the script's verdict logic was wrong, which is why it printed nothing.**
It required `status != Charging`, but this EC **keeps reporting `Charging`**
while holding the charge. What actually changes is the current: about **3.4 A**
while charging, near zero when held. Fixed to test the current, with a fallback
that assumes nothing about either field — capacity simply not rising for four
consecutive samples while at the ceiling. The lesson generalises: on this
hardware `status` is not a reliable indicator of whether charge is flowing.

**The handler defects are now patched**, since the feature is real:

- Both `show` handlers read the firmware instead of reporting a cache. WMBC
  implements `0x64` and `0x65`, so there was never a reason to report a
  remembered value that cannot confirm a write landed. They fall back to the
  cache on a failed read rather than claiming zero.
- `probe` tested `else if (output)` rather than the return code, so a genuine
  `BCPS` of 0 — the factory state here — left the cache at whatever it was
  initialised with.
- Both the probe decode and `charge_mode_show` now mask bit 2 (`(output >> 2) &
  1`) instead of shifting the whole nibble, so a stray bit 3 cannot read back as
  mode 2 or 3 from a node that only accepts 0 and 1.
- The write-side comment now says what the code does: `BCPS = Arg2` assigns all
  four bits, so bits 0, 1 and 3 are zeroed on every write. Harmless here, where
  `BCPS` reads 0 and nothing is known to use them, but it is a blind write and
  should become a read-modify-write if any of them ever turns out to matter.

The `60 <= limit <= 100` and `mode > 1` range checks stay. Still no firmware
basis — there is no clamp — but they keep every written value inside its field
width, which matters more now that the field is known to be live.

**Two later fixes on the same path, from the third review round.** Both are the
kind of thing only a second reader catches:

- **The mode write is skipped when the mode is unchanged.** Re-pointing an
  already-enabled ceiling at a new limit used to write the limit and then repeat
  the mode write. A failure on that redundant write reported an error to
  userspace *after* the limit had already moved. Comparing the cache is sound
  here for the reason stated above — nothing outside the two WMBD cases writes
  `BCPS`.
- **`power_supply_changed()` is called, and it must be called with
  `charge_lock` released.** Nothing in the power-supply sysfs or extension
  dispatch path emits it, so udev and upower kept serving the previous threshold
  until some unrelated battery event came along. The lock rule is not optional:
  it schedules work that re-reads the properties, and `get_property` takes the
  same mutex. That is why the setter uses `scoped_guard` and notifies after the
  scope closes — **the same rule the Mode key's uevent follows**, for the same
  reason. A suggested patch that called it inside the guard was declined on
  these grounds.

  Whether the core *also* emits it could not be checked here: this is a
  headers-only kernel tree with no `power_supply_sysfs.c`. Calling it is
  harmless if redundant and necessary if not, so it is called. That is a
  judgement, not a verified fact.

### Settled: `BCPC` *does* persist across a reboot — and the original 0 is unexplained

> **Read the heading, not the next four paragraphs.** They record the hypothesis
> that `BCPC` is cleared by a power cycle, and that hypothesis was **tested and
> disproven** — the resolution is further down, under "The test ran on 23 Oct
> 2026". **No boot-time re-apply is needed**, and a reader who stops after the
> first screen will take away the opposite. The paragraphs are kept because the
> guard they motivated is still in the code and still justified.

Observed 22 Oct 2026, and **not yet explained at the time.** `charge_limit` read
`0` where the recorded factory baseline was `100`:

```
charge_mode=0  charge_limit=0          # was 0 / 100 when first measured
```

The load log shows no failed read, so `charge_limit_show` did reach the firmware
and `BCPC` genuinely is 0. Neither candidate explains it: `charge_limit_store`
refuses anything below 60, and the battery extension writes `limit = 100` when
disabling. So **the leading hypothesis is that `BCPC` does not survive a power
cycle** — which would mean a ceiling is *not* persistent across reboots and has
to be re-applied at boot, as on many laptops. That is **one data point** and
must not be written up as a finding until it is reproduced from a known starting
value.

~~**There is a real hazard either way.**~~ **Guarded, 23 Oct 2026.**
`set_charge_mode()` now refuses to enable the mode while the ceiling is 0 or
out of range, and logs why. The guard sits in `set_charge_mode()` rather than
`charge_mode_store()` so it covers the battery ABI too, and its floor is **1,
not 60**: the node's own 60 keeps a sysfs write inside the field width, while
the battery path deliberately allows the full 1–99 range and shares this code.
It reads `BCPC` rather than trusting the cache, because a caller may not have
touched `charge_limit` since boot and this is the one place where being wrong
is expensive.

That makes the open question below **fail safe instead of fail silent** — if
`BCPC` does not persist, enabling the mode after a reboot now errors with a
clear message instead of latching a 0 % ceiling. It does not answer the
question, and the answer still decides whether a boot-time re-apply is needed.

**The refusal path cannot be reached through sysfs, and that is by design
rather than an oversight.** `charge_limit_store()`'s pre-existing
`60 <= limit <= 100` check rejects a 0 write outright — `echo 0 > charge_limit`
returns `-EINVAL` and logs `Invalid charge limit` — so the 0-ceiling state is
unreachable from userspace. The guard therefore exists for exactly one case:
**firmware state the driver did not write**, which is the observed hazard. An
attempt to demonstrate it by writing 0 through the node will fail at the range
check and never reach the guard; the message to look for is
`Refusing charge mode with a N% ceiling`, distinct from the range check's.

Which means **the persistence test doubles as the guard's test.** If `BCPC`
comes back 0 after a power cycle, `echo 1 > charge_mode` is refused, and that
is the guard firing where it was aimed. The success path is testable any time:
set a sane `charge_limit`, enable the mode, and the live `BCPC` read inside the
guard is what lets it through.

**The "node is lying" branch is eliminated.** A sentinel read on 23 Oct 2026
returned `0x0 (0) [implemented]` for both `0x65` and `0x64`, so these are
genuine firmware reads and `charge_limit` reports the truth: `BCPC` really is 0
and `BCPS` really is 0.

**The test ran on 23 Oct 2026 and the hypothesis is disproven.** `charge_limit`
was set to 80 with the mode off, the machine rebooted — a real one, the previous
boot had run 11 h 27 m — and the sentinel read came back:

```
method 0x65 arg 0x5a -> 0x50 (80) [implemented]
```

**`BCPC` survives a reboot.** `echo 1 > charge_mode` then succeeded, which is
the guard's success path: it read 80, found it sane, and let the write through.
So **no boot-time re-apply is needed**, and there is no systemd unit or udev
rule to write.

**What is now unexplained is the original 100 → 0.** No code path in this driver
can write 0 to `BCPC`: `charge_limit_store()` refuses anything below 60, and the
battery extension writes 100 or 1–99. So something outside the driver cleared
it, and a plain reboot is now ruled out as the cause.

The remaining candidate is **a colder power transition than a reboot** — a full
shutdown, a power-loss event, or the EC firmware resetting — none of which this
reboot exercised. The 22 Oct session that preceded the observation included
several reboots, a lost MOK enrolment and a GPU driver mess, so a hard power-off
in there is plausible and unrecorded.

### Answered 24 Oct 2026: a battery pull clears `BCPC`

**The variable nobody had captured is now captured.** A RAM upgrade required
removing the battery, which is a power-loss event to the EC rather than a
reboot, and it produced a clean same-day before/after with nothing else
intervening:

```
24 Oct 09:40, before the battery was removed :  charge_mode 0   charge_limit 100
24 Oct 13:1x, after it was refitted          :  charge_mode 0   charge_limit 0
```

So the hypothesis this section records as disproven-for-reboots is **correct for
a colder transition**: `BCPC` survives a reboot and does *not* survive losing EC
power. That closes the "unexplained 100 → 0" question — the 22 Oct occurrence
followed a session with a cold power event, which is consistent and needs no
other explanation.

**What does *not* follow: a boot-time re-apply is still not needed.** The
transition that clears it is one the user performs deliberately, with the
machine open and the battery out, not something a normal shutdown does. The
guard in `set_charge_mode()` is the right response and is exactly where it was
aimed: it covers firmware state the driver did not write, which is precisely
this.

**And the refusal path has now executed, for the first time since it was
written.** It was added on 23 Oct for a hazard that was observed but
unreachable through sysfs, so it shipped untested by construction — the note
then said the thing to look for is the guard's own message, *distinct* from the
range check's, because `charge_limit_store()` rejects a 0 write before the guard
is ever consulted. With `BCPC` genuinely 0 after the battery pull, that is
exactly what appeared:

```
$ echo 1 | sudo tee .../charge_mode
tee: .../charge_mode: Invalid argument
13:24:06 gigabyte_laptop: Refusing charge mode with a 0% ceiling, write charge_limit first
```

`charge_mode` and `charge_limit` both still read 0 afterwards, so the refusal
did not half-apply — which is the part that mattered, since the failure it
prevents is latching a 0 % ceiling. Recovery is to write a sane ceiling first:

```sh
echo 80 | sudo tee charge_limit && echo 1 | sudo tee charge_mode
```

**The CMOS block is a separate question and this event does not answer it.**
`power_on_time` read `0 0 0 0 0` both before and after, having gone from
`0 1 5 5 2` to zeroes at some point between 22 and 24 Oct. So whatever cleared
*that* was not this battery pull, and the "not stable across sessions"
conclusion stands on its own evidence.

**Everything else came back untouched**, which is worth recording because it
bounds the damage: the module loaded with the same `srcversion`, 30 attributes,
hwmon `gigabyte_laptop-isa-0000`, `platform_profile` `balanced`,
`max_brightness` 1, the event GUID still owned by `gigabyte-laptop-events`, and
`fan_preset` back at `auto` (driver state, as designed). DKMS, the signed `.ko`
and both key files on disk were never affected — only the firmware's enrolled
list was.

**Both observations stand and neither should be over-read.** `BCPC` was once
seen at 0 with no driver path that could have put it there, and `BCPC` once
survived a reboot intact. Those are compatible: the field persists across the
transition that was tested and something else cleared it on an occasion that was
not. **The guard is what makes that acceptable** — it covers precisely the case
of firmware state the driver did not write, which is the one thing actually
observed. Do not spend another reboot on this unless a 0 reappears; if it does,
record what kind of power transition preceded it, because that is the variable
nobody captured.

### The EC has a *restart* hysteresis, not just a ceiling — 23 Oct 2026

Observed as an apparent fault and it is not one. With `charge_mode 1` and
`charge_limit 80`, the battery sat at **76 %** on AC and would not climb:

```
ACAD/online = 1        status = Charging      current_now = 0
capacity    = 76       charge_mode = 1        charge_limit = 80
```

**`status` says `Charging` while `current_now` is 0**, which is the same
disagreement recorded under the `HONOURED` verdict — except there it was seen
*at* the ceiling and this is four points *below* it. So the EC does not merely
stop at the ceiling; it also refuses to resume until the charge falls further.

The evidence for the pair is already in this file: upower's hwdb entry for this
DMI match is `CHARGE_LIMIT=75,80`, a **start/stop** pair. 76 % sits inside that
75–80 dead band, so the EC had charged to 80, the battery drifted down on use,
and resuming was correctly withheld. Standard top-of-charge protection.

Three consequences:

- **`current_now` is the only reliable indicator of whether charge is flowing**,
  and that now holds across the whole band, not just at the ceiling. `status`
  reads `Charging` throughout. Charging in earnest measures about **3.4 A**
  (`current_now` ≈ `3380000`), confirmed again here.
- **The driver exposes no start threshold and cannot.** The firmware has no
  field for one — upower skips that write when the file is absent — so the 75 is
  the EC's own behaviour, not something this driver sets or can change.
- **Disabling the mode clears the band.** Writing `100` to
  `charge_control_end_threshold` set `charge_limit 100` and `charge_mode 0` in
  one transaction, and the battery charged from 76 straight past 80 — observed at
  83 % and 3.38 A. The ceiling is what the hysteresis guards; with it off,
  ordinary charging resumes immediately.

**So "stuck below the ceiling on AC" is expected, not a bug.** Check
`charge_mode` first: on the occasion above it still read `1` because an attempt
to disable it had not landed.

### Keyboard backlight: verified end to end, 22 Oct 2026

Installed through DKMS, signed, `installed == loaded`. The node appears with the
measured ceiling and a brightness seeded from hardware:

```
/sys/class/leds/gigabyte_laptop::kbd_backlight/
  brightness=1  max_brightness=1  brightness_hw_changed present
```

No `Keyboard backlight unsupported by this firmware` in the load log, so the
runtime capability gate passed. Writes through the LED node take effect.

**`upower` picked it up, and the whole desktop path works.** Round trip over the
same D-Bus call KDE's slider makes, with no polkit prompt:

```
GetMaxBrightness                -> i 1
SetBrightness(0) -> sysfs brightness 0   (keyboard off)
SetBrightness(1) -> sysfs brightness 1   (keyboard on)
```

**Check `GetMaxBrightness`, not `NativePath`.** `NativePath` reads `""` even
when it is working — `upower` 1.91.5 exposes the property on the interface but
does not populate it for this object. It was used as the success criterion at
first and was simply the wrong test; `GetMaxBrightness` returning the real
ceiling instead of `0` is what proves discovery.

**The hardware-changed direction is confirmed too.** After pressing Fn+Space,
`brightness_hw_changed` reads `1` instead of `ENODATA`, so the `0xF6` event does
reach `led_classdev_notify_brightness_hw_changed()`. Both directions work.

(`busctl --system monitor` needs root — `BecomeMonitor` is privileged — so use
`sudo` if watching upower's signals.)

### What the keyboard backlight work actually bought, honestly

**Fn+Space already toggled the backlight before any of this**, entirely inside
the EC, and that was recorded from the first day. So this did not make the
keyboard light up; it was never broken. What it adds, in descending order of
real value:

- **Software control at all.** Before, the only way to change it was the
  physical key. Now it is scriptable and automatable — "backlight off on
  battery" becomes a rule rather than a habit.
- **The state is readable.** Nothing could previously tell whether it was on.
- **The desktop's own control works**, and tracks the key.
- **Save/restore across reboots**, free from systemd's `leds` rule — which is
  only true because the LED carries `LED_RETAIN_AT_SHUTDOWN` alongside
  `LED_BRIGHT_HW_CHANGED`. Without it `led_classdev_unregister()` zeroes the
  brightness on the way out, and systemd would dutifully save and restore a 0.
  Worth naming, because this bullet claimed the benefit while the mechanism
  delivering it went unrecorded.

**And what it does not buy: more levels.** It is a two-level backlight, so the
"slider" is a toggle. For a user who is happy pressing Fn+Space, the practical
gain is small, and it would be dishonest to present this as a feature that
unlocked something. It is a correct, standard ABI over a control that already
worked by hand — worth having for automation and for upstreaming, not a
transformation.

The genuinely interesting by-product is the `0xF6` event discovery: it proved
`KBLL` is live EC-maintained state, which is what made `max_brightness`
measurable without a single speculative write.

### Mode key notifications: working, 22 Oct 2026

`tools/gigabyte-fan-preset-notify`, started by its systemd **user** `.path`
unit, puts a toast on screen for each Mode press. Confirmed on hardware — the
notifications appear when the preset changes.

```
systemctl --user is-enabled …notify.path     -> enabled
systemctl --user is-enabled …notify.service  -> static
systemctl --user is-active  …notify.service  -> active
CPU ticks since start         -> 1      (total, across 23 presses this boot)
memory                        -> 268 KB cgroup / 1.6 MB RSS
```

One CPU tick for a session's worth of notifications, because the process is
blocked in `poll()` the whole time and only wakes to fork `notify-send`.

**It is the `.path` unit that gets enabled, and the service is `static`** — the
`.service.in` has no `[Install]` section, so `enabled` was never achievable for
it. This block said `is-enabled -> enabled` without naming a unit, which reads
as a claim about the service. `USAGE.md` had it right all along.

**C, not Python, and the reasoning is worth keeping.** Python was the first
suggestion and was habit rather than a decision: a resident interpreter costs
~20 MB to sit in a `poll()` loop that fires a few times a day. `poll()` is a
syscall and every other language wraps it; this repo is already C with a
Makefile, so C added no toolchain, no language and no dependency. Lua would have
been worse than either — `poll()` is not in its standard library, so it would
have meant adding `luaposix` to avoid writing forty lines.

**Memory safety by construction, not by care**, which is the part to preserve if
anyone edits it: no `malloc` anywhere, fixed buffers, `read()` bounded by
`sizeof(buf) - 1`, `execlp` rather than `system()` so there is no shell, and the
value read from sysfs only ever selects an *index* into a compile-time table. No
kernel-supplied string reaches the exec, so there is nothing to quote, escape or
truncate.

**Two traps, both verified rather than assumed:**

- **The attribute must be read once before `poll()` will block.** Until the
  event counter is consumed, `poll()` returns immediately and a loop around it
  spins at 100 % CPU. That first read is also current state rather than a
  change, so it is recorded and not announced.
- **`POLLERR` accompanies every `POLLPRI`** on a sysfs attribute and is not an
  error on its own. A failed *read* is, and means the attribute has gone.
  ~~The program exits non-zero so the service manager decides.~~ **Superseded:
  it now re-opens instead**, because the service manager turned out to be unable
  to recover it — a failed read triggers `RETRY_LIMIT` (30) attempts at
  `RETRY_INTERVAL_S` (2 s), about a minute, and `exit(1)` is still the terminal
  outcome only after all of them fail. A failed open *at startup* remains fatal
  immediately. See "The fix: the watcher re-opens itself". Tested against a
  missing attribute.

It reacts to the **key only**, because the driver calls `sysfs_notify()` only
from the key path. A sysfs write to `fan_preset` or `fan_mode` raises nothing,
which is correct: the caller of a write already knows what it did.

**The `.path` unit has not been shown to restart it after a module reload, and
USAGE.md used to claim it did.** Corrected 23 Oct 2026 from the journal: across
six boots, every start of the service sits immediately after a `-- Boot --`
marker and none coincides with the mid-session `rmmod`/`modprobe` that
`scripts/install-dkms.sh` performs. The service also shows no stop across those
windows, so it either survived with a stale descriptor or sat dead without
systemd noticing.

`PathExists=` watches via inotify and inotify on `/sys` is not contractually
reliable, so this is the expected behaviour rather than a surprise. **I asserted
the opposite earlier in this session on bad evidence** — ten logged starts,
every one of them a login, counted as proof of re-firing. Check the boot markers
in `journalctl --user -u <unit>` before reading a start as a reload.

### Measured 24 Oct 2026: the watcher survives a reload with a dead descriptor

The reload test that the paragraph above asked for has now been run, and it
returned the **worst of the three possible outcomes**: the watcher neither dies
nor keeps working. It survives, systemd reports it healthy, and it never sees
another event.

```
watcher PID 2332   started 09:15:48   NRestarts=0     <- the pre-reload process
systemctl --user is-active                -> active   <- systemd sees nothing wrong
watcher fd 3   inode = 43039
live fan_preset inode = 63096                         <- a different file
```

The kernel side was never affected. Six Fn+F7 presses after the reload were all
registered by the driver, and all six were missed by the watcher:

```
09:32:05  Stopping Gigabyte laptop WMI driver
09:32:07  Gigabyte laptop WMI driver started
09:32:07  Mode key: fan preset silent
09:32:09  Mode key: fan preset normal
09:32:13  Mode key: fan preset gaming
09:32:14  Mode key: fan preset auto
```

**Why it looks healthy.** `poll()` on a kernfs node whose module has gone does
not return `POLLERR` and does not fail — it simply never becomes ready again.
The program's own error handling is sound and never fires, because there is no
error: `read()` is never reached. So the exit-non-zero-on-read-failure design
recorded above protects against the driver being *absent*, not against the
attribute being *replaced*.

Three things follow, and they settle every open question on this unit:

- **The `.path` unit does not recover it.** It stayed at its login timestamp
  (`ActiveEnterTimestamp` 09:15:48, `Result=success`) across the reload. That
  independently confirms the inotify-on-`/sys` reasoning above, by observation
  rather than by inference from boot markers.
- **The udev rule the review finding asked for would NOT have fixed this**, and
  I said it would before checking. `SYSTEMD_USER_WANTS=` "adds dependencies of
  type `Wants=`" (`systemd.device(5)`), a `Wants=` enqueues a **start**, and a
  start against an already-active unit is a no-op — the identical no-op that
  defeats `PathExists=`. Verified rather than reasoned: `systemctl --user start`
  against the running watcher returned 0 and left the PID at 6979.

  So the finding correctly identified a real bug and proposed a remedy for the
  wrong link in the chain. **Do not add the rule.** It would be inert code
  carrying an implication that recovery is handled.
- **`systemctl --user restart` is the right recovery command**, not `start`,
  which is exactly what the `e33932d` fix changed in USAGE.md. A `start` against
  an already-`active` unit is a no-op, so it would have left the dead descriptor
  in place. That finding was right for precisely this reason.

**Diagnose it by inode, not by unit state.** Unit state is useless here; it
reads `active` either way. The one-line check:

```sh
PID=$(systemctl --user show -p MainPID --value gigabyte-fan-preset-notify.service)
stat -c %i /sys/devices/platform/gigabyte_laptop/fan_preset   # live
for f in /proc/$PID/fd/*; do                                  # what the watcher holds
	case "$(readlink $f)" in *fan_preset*) stat -L -c %i "$f";; esac
done
```

Equal means healthy. Different means notifications are silently dead and the
service needs a `restart`.

**This snippet read `stat -L -c %i /proc/$PID/fd/3` and that was wrong**, for
the reason given under "Verified end to end on hardware" below: the descriptor
number moves once the watcher has re-opened itself, so a hardcoded `fd/3`
reports `No such file or directory` on a perfectly healthy process. Matching on
the symlink target is the fix, and both copies of the diagnostic now do it.

**Note for anyone running the test:** reloading the module breaks the toasts
until the watcher is restarted, and nothing on screen says so. Say that before
asking someone to run it. The reload also resets `fan_preset` to `auto`, since
the ring is driver state; `charge_mode`/`charge_limit` survive because they live
in the EC.

### The fix: the watcher re-opens itself, and no unit does it for it

**Orphaned-kernfs semantics, measured rather than reasoned.** The behaviour
depends on *where `poll()` is* when the node is removed, and that asymmetry is
the whole bug. Measured on this kernel with a throwaway cgroup — cgroups are
kernfs too, and a user can create and `rmdir` one under their own
`user@1000.service` slice without root, which makes this testable without
touching the driver:

```
node live                     waited 2001ms  ret=0  revents=0x0000  read=21
removed while poll in flight  waited 2001ms  ret=1  revents=0x000a  read=-1
every poll after that         waited    0ms  ret=1  revents=0x000a  read=-1
```

`0x000a` is `POLLPRI | POLLERR`. Three facts follow, and all three are needed:

- **Removal does not wake a poll already in progress.** It slept out its full
  timeout. With `-1` that is forever, which *is* the original silent deafness:
  `poll(&pfd, 1, -1)` meant the loss detection sitting on the next line never
  ran. The program's logic was right all along; it sat behind a wait that
  cannot finish.
- **A poll entered after removal returns instantly**, and reports `POLLPRI`.
  So the loss arrives as `ret > 0` — indistinguishable from a real keypress by
  the poll result alone.
- **Only the read distinguishes them.** kernfs refuses a read on a removed
  node, while the fd, the path, `poll()`, `revents` and the unit state all keep
  looking healthy.

So the fix is two parts, and **having only the first is worse than having
neither**. `poll()` takes `POLL_INTERVAL_MS` (5 s) to escape the first case,
*and* the read probe runs on **every** wake rather than only on a timeout, to
catch the second. A version that probed only on `ret == 0` treated the POLLERR
storm as a stream of events and pegged a core — see below.

An inode comparison is the right *manual* diagnostic but is weaker in code:
inode numbers can be reused, and a reused number would read as healthy against
a still-orphaned fd.

**It re-opens rather than exits, and that is the whole point.** Exiting hands
recovery to the service manager, which cannot do it for the reason above, and
there is a race even if it could: the reload window measured 2 s (09:32:05 to
09:32:07), shorter than any sane timeout, so the trigger fires while the old
process is still active and is swallowed. Re-opening needs no activation path,
no udev rule, no root and no packaging, and survives any number of reloads.

Startup behaviour is deliberately unchanged: a failed open at startup is still
fatal, because the `.path` unit only starts the watcher once the attribute
exists, so an unopenable attribute then means something is wrong rather than in
flux. Only a mid-life loss self-heals.

**The idle cost is unchanged**, which was the one regression risk: 0 CPU ticks
across 33 s and roughly six timeout wakes, `wchan` = `poll_schedule_timeout`.
The "blocked in `poll()` the whole time" property survives; it is now a timed
wait rather than an infinite one.

Both unit files documented the old, non-existent chain — the `.path` comment
claimed it restarts the service on a later module load "because the service
exits when the driver goes away", and the `.service.in` comment justified
omitting `Restart=` on the same false premise. Both corrected to say what
actually happens and why no unit dependency can help.

### The first attempt pegged a core, and the false pass is the lesson

Shipped and installed before it was understood. The first patch added the
timeout but probed only on `ret == 0`, so once the node was orphaned every
`poll()` returned `POLLPRI|POLLERR` in 0 ms, the read failed, and the loop
`continue`d — a full-core spin that ran until the service was stopped by hand:

```
PID 8200  elapsed 02:10  ticks 11444        (~88% of a core for its whole life)
sampled 3s apart: 11449 -> 11748            (delta 299 == one core pegged)
state Rs   wchan 0
```

**It shipped because the verification measured the wrong process.** The test
resolved its PID with `pgrep -f '^\./gigabyte-fan-preset-notify$'`, which
matched the harness's own shell, and reported a comfortable `0 ticks`. The same
mistake with `$!` had already caught the shell wrapper one call earlier. The
tell was in the output and went unread: a process one second old cannot have
**25592** accumulated ticks.

Three rules, all paid for:

- **Sanity-check a baseline before trusting a delta.** Initial ticks on a
  one-second-old process must be ~0. Any other number means the PID is wrong.
- **Resolve a service's PID with `systemctl --user show -p MainPID`**, never
  `pgrep -f` from inside the thing being measured. The PID 8200 figure above was
  sound precisely because it came from systemd.
- **Testing the healthy path proves nothing about the failure path.** The spin
  lived entirely in the orphaned-node branch, which the passing test never
  entered. The cgroup probe above exists because that branch needed a way to be
  exercised without a module reload.

**Guarded in the unit now**, because the fix being right is not a reason to
leave the failure mode uncapped: **`CPUQuota=5%`, and that directive alone.**
This originally read "`CPUAccounting=yes` and `CPUQuota=5%`", which credited a
directive that does nothing — **systemd 259 removed `CPUAccounting=`** and logs
"Support for option CPUAccounting= has been removed and it is ignored" on every
daemon-reload. The guard is undamaged: cgroup v2 reports `cpu.stat`
unconditionally, so `CPUUsageNSec` stays readable with no directive asking for
it. The same bug would now cost 5% of one core and show as CPU time on a process
that should have none, instead of pegging a core silently.

### Verified end to end on hardware, 24 Oct 2026

The last untested step -- the re-open succeeding against the real driver
attribute -- is confirmed. A module reload with the watcher running produced:

```
Oct 24 10:04:23 gigabyte-fan-preset-notify[9104]:
    /sys/devices/platform/gigabyte_laptop/fan_preset: re-opened after a driver reload
```

and the process healed in place rather than being restarted:

```
PID 9104 before and after    NRestarts=0    started 10:03:20 (pre-reload)
held inode 63814 == live inode 63814
open fds: 0 /dev/null, 1 + 2 journal sockets, 4 the attribute   <- no leak
CPU ticks over 4s: 0        wchan poll_schedule_timeout
CPUUsageNSec for the whole life: 84 ms, forks for notify-send included
```

**The descriptor number moves, and a diagnostic that hardcodes `fd/3` is wrong
after the first re-open.** `arm()` opens the replacement *before* closing the
old one, so the new fd takes the next free number while the old one is still
held. ~~The fd is 4 after one recovery, 5 after two.~~ **Wrong — it does not
climb, it alternates.** Corrected 24 Oct 2026: the open-before-close means the
replacement lands on 4 while 3 is busy, then 3 is closed and freed, so the
*next* recovery lands back on 3. The sequence is 3 → 4 → 3 → 4, and the same
mistaken "4 then 5" is in commit `3af934a`'s message, where it cannot be fixed.
Exactly one is ever open -- the listing above confirms it -- but match on the
symlink target rather than the number:

```sh
PID=$(systemctl --user show -p MainPID --value gigabyte-fan-preset-notify.service)
for f in /proc/$PID/fd/*; do
	case "$(readlink $f)" in *fan_preset*) stat -L -c %i "$f";; esac
done
stat -c %i /sys/devices/platform/gigabyte_laptop/fan_preset   # must be equal
```

Caught while verifying this, by a check of mine that said `No such file or
directory` for `fd/3` on a perfectly healthy process.

### `charge_control_end_threshold`: verified end to end, 22 Oct 2026

The standard ABI now exists and the whole chain works.

```
/sys/class/power_supply/BAT1/charge_control_end_threshold
  exists, mode 644                       <- property_is_writeable did its job
  reads 100 with no ceiling in force
  echo 80  -> reads 80, driver charge_mode reads 1   (both views agree)
  echo 100 -> back off
```

**udev imports upower's hwdb entry now**, which it could not before because the
attribute was absent:

```
E: POWER_SUPPLY_CHARGE_CONTROL_END_THRESHOLD=100
E: CHARGE_LIMIT=75,80
```

**And upower exposes the whole interface**, which is the part that matters:

```
.ChargeThresholdSupported          b       true
.ChargeThresholdEnabled            b       false
.ChargeEndThreshold                u       80      <- from the hwdb, not the firmware
.ChargeStartThreshold              u       75
.EnableChargeThreshold             method  b
```

The D-Bus method works, which is the real desktop route:

```
EnableChargeThreshold(true)  -> sysfs 100 -> 80,  charge_mode 0 -> 1
EnableChargeThreshold(false) -> sysfs 80 -> 100,  charge_mode 1 -> 0
```

No polkit prompt from a user shell. Note that `ChargeEndThreshold` 80 and
`ChargeStartThreshold` 75 are upower's **hwdb-suggested** pair for this DMI
match, not a reading of the firmware — the firmware has no start threshold at
all, and upower skips that write when the file is absent.

**A claim I made and had to withdraw.** This was pitched as giving a native
slider in KDE System Settings, on an investigation's finding that powerdevil's
`chargethresholdhelper` contained the sysfs literals. **That is false on this
machine**, checked four ways: nothing in `powerdevil-6.7.5-3` references
`charge_control_end_threshold` or even `power_supply`, and the helper holds no
path literals at all, though the binary and both polkit actions do exist. The
only consumers on this system are `/usr/libexec/upowerd`, the upower udev rule
and its hwdb.

So the desktop path is real but it runs **through upower's D-Bus interface**,
not through powerdevil reading sysfs. Whether Plasma 6.7.5 surfaces a slider on
top of that interface is still not demonstrated here, and should not be claimed
without checking. What *is* demonstrated: any D-Bus client, `upowerctl`, GNOME,
and TLP can all drive it.

### Step 6 leads, in order of cost

1. ~~**`0xF6` / `KBLL` over WMI**~~ — **done, shipped as Step 6a.** Brightness
   only, read/write, in firmware, on AMD, and it needed no reverse engineering,
   which is why it went first. See "Keyboard backlight: verified end to end".
   The leads below are what remains, and both are about **colour**.
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

### Two review findings declined, with reasons — 23 Oct 2026

Recorded so they are not re-raised and re-investigated:

- **"Hide hwmon `temp3` when `gaming_family` is set."** Declined. `temp3` does
  read `+0.0 °C` here, and the firmware reason is known — `ec_read(0x62)` lands
  on an undeclared `ERAM` offset. But `gaming_family` covers **every**
  `GIGABYTE GAMING` model, and the evidence is one machine. Hiding a channel
  family-wide from a `GA65TH` observation is the same over-generalisation this
  file warns about for method IDs. The finding itself asks to "confirm the
  Gaming generations share the relevant ERAM layout first", which is exactly
  what cannot be confirmed here. A temperature reading 0 is cosmetic, hwmon
  consumers handle it, and the change would diverge from upstream for a
  non-bug in code headed upstream. Revisit only with a second machine's dump.
  **Strengthened 26 Oct 2026**: the Aero firmware's own comment labels EC `0x62`
  the MLB (motherboard) temperature, so the channel's *meaning* is pinned and
  it is upstream's label that is right. Hiding it would have been removing a
  correctly-named channel on the strength of one machine not populating it.

- ~~**"Test the DNF upgrade transaction for `akmod-aorus-laptop`."**~~
  **Superseded, and my stated reason was wrong.** I recorded here that
  "`kmodtool` offers no hook for `Obsoletes`, so only
  `gigabyte-laptop-kmod-common` can obsolete its predecessor". That is false,
  and the spec's own comment said the same thing. See "`kmodtool` does have an
  obsolete hook" below.

### `kmodtool` does have an obsolete hook — `--help` does not list it

`kmodtool` 1.2.1 implements **`--obsolete-name`** and **`--obsolete-version`**,
and `kmodtool --help` does not mention either. The usage text lists only
`--filterfile`, `--for-kernels`, `--kmodname`, `--noakmod`, `--repo` and
`--target`, which is how two separate notes — the spec comment and a decline
recorded in this file — came to assert that generated subpackages cannot carry
`Obsoletes`.

**Grep the script, do not trust its usage text.** `grep -i obsolete
/usr/bin/kmodtool` shows the handling at lines 114, 170, 206, 265, 400 and the
option parsing at 538 and 546. A dry run proves it:

```
$ kmodtool --target x86_64 --repo rpmfusion --kmodname gigabyte-laptop-kmod \
           --obsolete-name aorus-laptop --obsolete-version 0.2.0-2 --akmod
Provides:         akmod-aorus-laptop = 0.2.0-2
Obsoletes:        akmod-aorus-laptop < 0.2.0-2
Provides:         %{kmod_obsolete_name} = 0.2.0-2
Obsoletes:        %{kmod_obsolete_name} < 0.2.0-2
```

Both kmodtool invocations in `gigabyte-laptop-kmod.spec` now pass them, and
`rpmspec -P` confirms the expansion carries all four lines for the real
`akmod-aorus-laptop` and `kmod-aorus-laptop` names.

Two constraints found in the script and worth keeping:

- **Both options are required together**, or kmodtool exits 2 with "you need to
  provide both --obsolete-name and --obsolete-version" (line 606).
- **The version bound must clear the old package's *release*.** `aorus-laptop`
  was `0.2.0-1` and this is `0.2.0`, so `%{version}` alone would exclude the
  very package it must replace. `%{version}-%{release}` gives `0.2.0-2.fc44`
  and matches — the same reasoning that made `Release: 2` load-bearing for the
  hand-written `Obsoletes` in the other two specs.

So the rename is now handled end to end by the packaging, and the manual
`dnf remove akmod-aorus-laptop` step is **no longer required**. `INSTALL.md`
says so.

## Open decisions — all closed, kept for the record

Every entry here is struck through, which is the point: these are the questions
that were open and how each was answered.

~~**Whether to try the indexed fan curve.**~~ **Answered on hardware,
23 Oct 2026 — it is inert.** See "Step 4 is closed". Nothing about fan duty
remains open.

~~**Whether `CRAF` (`0x57`) does anything on this unit.**~~ **It already did.**
`CRAF` reads `1` whenever `fan_mode` is 1, so the driver has been driving it as
silent mode all along; the CWH analysis named a field this file had left
anonymous, it did not find a new control.
~~**Whether `BCPC` survives a power cycle.**~~ **Answered twice, and the second
answer completes the first.** A reboot does not clear it — 80 survived one on
23 Oct 2026 — so **no boot-time re-apply is needed**. A **battery pull does**
clear it, measured 24 Oct 2026 from a clean 100-before/0-after, which also
explains the original unattributed 100 → 0. See "Answered 24 Oct 2026: a
battery pull clears `BCPC`". The guard in `set_charge_mode()` covers exactly
that case and has now fired in anger.

**Nothing is open in this section any more**, and that is a claim about *these
questions only* — emphatically not a claim that the project has nothing left to
do. **Read the open work off the Phase 3 table and nowhere else.** This
paragraph used to enumerate the open rows and give a count; it went stale three
times doing so (one row, then four, then seven), which is the whole argument for
not repeating the list here. The table is the single source.

## Decided: the userland GUI is a separate project — so sysfs is a contract

**Recorded 29 Oct 2026.** A separate project will build the userland GUI for
every control this driver exposes. That is the right split and it is the
standard one: **the driver provides mechanism, userspace decides policy.** No
scheduling, no profiles-by-time-of-day, no "limit charge unless I am
travelling" logic belongs in here.

**The consequence is what matters for the work queued below.** The sysfs
surface stops being this machine's private debug interface and becomes an
interface another codebase is written against. Three things follow:

- **A node that reports a wrong or meaningless value is now a bug with a
  downstream victim**, not a cosmetic flaw. `battery_cycle` and the two
  `usb_charge_*` toggles read `0` because the firmware has no such method, and
  a GUI reading `0` will display "0 cycles" to a user. That moves the typed-read
  fix from tidy-up to prerequisite.
- **Ambiguous units are an integration hazard.** `fan_pwm` is raw percent and
  hwmon `pwm1` is the same reading scaled to 0–255; `fan_custom_speed` accepts
  0–255 but has no proportional effect by any route. Each is now documented in
  `USAGE.md`, and `USAGE.md` is the document the GUI project should be written
  against.
- **Node semantics should not churn once the GUI exists.** Anything that
  changes a node's range, units or meaning — the `gpu_boost` bound, the duty
  scale decision — is cheapest to settle *before* another codebase depends on
  it, which is an argument for doing those first rather than last.

**What the GUI will want that does not exist yet**, so it can be planned for
rather than discovered: a working dGPU attach/detach pair (the `0x51` bound
fix), the MUX read (available today from `/sys/class/drm/card*-eDP-*/status`,
no driver work needed), and an honest answer on whether `perf_mode` does
anything on the CPU side.

## Decided: upstreaming comes last

Patches go to `tangalbert919/gigabyte-laptop-wmi` **after** the goals here are
met, not incrementally. The fork exists at `origin` so the work has somewhere to
live meanwhile.

Sorted by how likely each is to be accepted, for when that time comes:

| Candidate | Why it should go up |
|---|---|
| `gpu_boost_store()` oops (#45) | Dereferenced `gigabyte` before assigning it; any write oopsed the kernel |
| `gpu_boost` split detach/restore pair | **Fixed 29 Oct 2026 — the node now takes the full 0-4 the firmware implements.** Was: `mode >= 3` blocked only when `has_dgpu_ejector` is set, then `if (mode > 3)` permitted 3 — a dGPU eject — while rejecting 4, its restore. The defect was the asymmetry, not the feature. See Hazards |
| Typed read refuses a BUFFER | An unimplemented ID echoes its argument into an `int` and returns success, so an absent method reads as a genuine `0`. Five lines, and it fixes a live `0xFA` silent-fan misdetection on every model outside the three early-exit DMI families |
| Duty clamp (#46) | Duties above `FAN_DUTY_MAX` stop the fans on an AERO 17-XA |
| Void-WMBD tolerance | `set_devstate()` reported `-EINVAL` for a third of this firmware's setters; see below |
| Probe hardening | One absent optional method no longer aborts the whole module |
| `memcpy` clamp | Size-aware getter; the old `void *` hid a five-byte caller |
| `pwm_enable` enum | Upstream had `AUTO` and `MANUAL` the wrong way round vs the hwmon ABI |
| `hwmon_read()` error propagation | Returned success with `*val` unwritten on a failed read |
| NULL-safe DMI family match | Four unchecked `strcmp`s on `DMI_PRODUCT_FAMILY` |
| `fan_lock` | Three entry points doing read-modify-write on `fan_mode` unserialised |

The rename, the `fan_preset` ring and the hotkey input device are this fork's
own direction and should **not** be offered upstream without asking first — the
rename in particular would break every downstream packaging reference.

**Do not argue the `gpu_boost` cap from a quotation — 26 Oct 2026.** A
justification drafted for that patch quoted the upstream maintainer in support
of it, and the quotation does not exist: it is **a commit message spliced to a
code comment across an ellipsis**, and he has since committed the opposite
position. Sending it would have attributed to a maintainer a view he does not
hold, in the first patch this fork ever offered him.

**Argue from the code, which is sufficient on its own.** `Case (0x51)` value 3
is `Notify (^^GPP0.PEGP, 0x03) // Eject Request` — the firmware's own comment —
and `gpu_boost_store()` permits 3 while rejecting the harmless 4. That needs no
endorsement. The general rule, which is the part worth keeping: **never
assemble a quotation from two sources**, and check a maintainer's current
position before citing an old one.

## Settled decisions

### Step 3 design — superseded, kept for the record

> **This is the original GPU-power design and is _not_ what shipped.** It
> assumed `perf_mode` reached the GPU's TGP, which turned out to be false on
> this firmware. The design that shipped is **"Step 3 design: profiles over fan
> policy, with PWM taking precedence"** further down, and that is the only
> current contract. Nothing here describes live behaviour.

- ~~**A profile switch sets `perf_mode` and `dynamic_boost` only.**~~ Fan
  settings were to be left alone, so a custom fan curve survived profile
  changes. Target mapping, never implemented:

  | Profile | `perf_mode` | `dynamic_boost` |
  |---|---|---|
  | `quiet` | 0 eco | off |
  | `low-power` | 0 eco | off |
  | `balanced` | 1 | off |
  | `balanced-performance` | 1 | on |
  | `performance` | 2 boost | on |

- **Keep the raw `perf_mode` node alongside `platform_profile`.** Still true,
  though for a different reason now: nothing writes it, and it stays available
  for scripting and for the day a BIOS update makes NVPCF work.
- ~~**Test `amd_pmf.force_load=1` before writing Step 3**~~, so it is known
  whether the handler will be sharing the aggregate with `amd-pmf`. Not done,
  and no longer blocking: the handler shipped and registered cleanly as the sole
  handler. Still worth trying on its own merits —
  `sudo grubby --update-kernel=ALL --args="amd_pmf.force_load=1"`, reboot, then
  read `/sys/class/platform-profile/*/{name,profile,choices}`. Revert with
  `grubby --remove-args`.
- **Keep `tuned`; do not install `power-profiles-daemon`.** Still current.

### Step 4: writable PWM is reverted, and here is what the firmware does

**Writing a duty is read-only again.** ~~Two mechanisms were tried~~ — **four
were, in the end**; this section is the chronological record and the two below
are only where it started. None gives proportional control, one of them stops
the fans, so shipping a writable attribute that userspace or CoolerControl could
trigger was not defensible. The full tally is in "Step 4 is closed".

| Method | Writes | Result on hardware |
|---|---|---|
| `0x6A` `FAN_FIXED_MODE` | `ADJF`, **one bit** | Cannot carry a duty. Latching it runs the fans flat out whatever duty was set, which is why every value read back as maximum RPM. This is all `fan_turbo` ever did. |
| `0x70` `FAN_AUTO_MODE` | `FAN1`, `FAN2`, `TFAN=0`, `GFAN=1` | Targets of 25/50/75% were **ignored** — the EC kept its own curve at 22% and the fans stayed at idle RPM. A target of **100% stopped both fans**. |

Read the field widths before believing a method sets a duty:
`ADJF`, `TFAN`, `GFAN` are 1 bit; `FAN1`, `FAN2`, `FDTY`, `GDTY` are 8.

**What was kept.** `pwmX` read scaling is correct and stays: `0x50` returns
`FDTY`, the live duty in percent, and hwmon wants 0–255, so an EC duty of 22
now reads `56` instead of `22`. `pwm_enable` reporting was also wrong upstream
and is fixed — see the enum note below.

**`0x46`/`0x47` tried and rejected — three mechanisms down.**

```
fan_mode 3, idling at ~45C, 0x46 and 0x47 written together each step:
duty 30 -> 1666 RPM
duty 40 -> 1657 RPM
duty 50 -> 1666 RPM
duty 60 -> 1666 RPM
duty 70 -> 1666 RPM
```

Flat, and flat at exactly the idle figure. **The test was also badly designed,
and the reasoning behind it was wrong — both worth recording so neither is
repeated:**

- **`fan_mode 3` is the wrong mode to test a duty in.** Mode 3 sets `TENF`,
  which is the *curve* mode: the EC drives the fans from `XFNW`, so its control
  loop overwrites any duty on its next cycle. A duty can only stick in a mode
  where the EC is not computing one.
- **`FDTY` is the EC's output, not an input.** The driver reads `pwm1` from
  `0x50`, which returns `FDTY` — the live duty. Writing the register the EC
  publishes its own result into was never going to hold.
- **The claim that this was "a combination nothing had tried" was wrong.**
  `0x70` already writes `FAN1` and `FAN2`, and those were ignored. Adding
  `FDTY`/`GDTY` to targets that are already ignored is not a new mechanism.

**The decisive finding is that the DSDT cannot answer this.** Every reference to
`FDTY`, `GDTY`, `FAN1`, `FAN2`, `TENF`, `ADJF`, `GFAN` and `TFAN` in the whole
table is inside `WMBD` (assigning it) or `WMBC` (returning it). **No AML reads
or tests any of them.** The methods are a pure pass-through to EC RAM, and what
the EC's own firmware does with those bytes is not in any table we can dump. So
there is no more static analysis to do here — only experiments, and only in
modes where the EC is not running a curve.

Field widths, for reference: `TFAN`, `GFAN`, `TENF`, `ADJF`, `CRAF` are
**1 bit**;
`FAN1`, `FAN2`, `FDTY`, `GDTY`, `FLVL` are **8**; `XFNW` is **24**.

**The lead that was left — and it has since been tested and closed.** See
"Step 4 is closed" above for the hardware result; this is the reasoning that
made it worth trying, and the read-back it relied on. `fan_mode 3` plus
`fan_curve_index`
and `fan_curve_data` (`WMBD 0x68` → `XFNW`). It is the firmware's own
proportional mechanism, which is the argument for it, and unlike every duty
write **it can be verified**: `WMBC 0x68` writes a request index to `XFNR`,
sleeps 100 ms and returns `XFN1`, so a written point can be read back.

```asl
Case (0x68) { ^^SBRG.EC0.XFNR = Arg2
              Sleep (0x64)
              Return (^^SBRG.EC0.XFN1) }
```

That read-back is what makes it worth trying: it distinguishes "the store does
not work" from "the store works and the EC ignores the curve", which none of the
duty experiments could. GigaMate reports the indexed store is inert on an
AERO X16, a different model — test rather than assume.

Note the driver's current `fan_curve_data_store()` builds `data << 8 | index`,
with a commented-out alternative packing speed/temp/index, and `XFNW` is 24
bits. The packing was **a guess**; a third-party analysis now names the three
fields — see "A third-party CWH analysis names the `XFNW` fields" below — and
the read-back is still the way to confirm it.

### Step 4 is closed: the indexed curve is inert, and that was the last lead

**Tested on hardware 23 Oct 2026.** The mode state matched GCC's Custom recipe
exactly before anything was written — verified by reading all four flags, not
assumed:

```
0x57 CRAF -> 0    0x71 FANB -> 0    0x67 TENF -> 1    0x6A ADJF -> 0
```

The curve was empty to begin with. All sixteen indices read `0`, and that is a
real reading rather than the echo artefact: `WMBC 0x68` returned `0` for index
`5`, `10` and `15` instead of echoing them back. **So the firmware ships no
default curve** — which incidentally explains the old `0x46`/`0x47` result, where
mode 3 gave a flat 1666 RPM. The EC was not overriding a duty with its curve; it
had no curve to run.

Then one point was written and read back:

```
fan_curve_index 0, fan_curve_data 0x3C28   (duty 0x3C=60%, temp 0x28=40C)
WMBC 0x68 index 0            -> 0x0        ** nothing **
WMBD 0x68 arg 0x3C2800       -> replied 0x3c2800
WMBD 0x68 arg 0x3C2801       -> replied 0x3c2801     (1-based index too)
WMBC 0x68 index 1            -> 0x0        ** nothing **
```

**`XFNW` holds exactly what was written. `XFN1` never populates.** The ACPI
store lands in EC RAM and the embedded controller does nothing with it — the
precise failure this file already warns about under "Method IDs we are not using
yet": a WMBD case that writes a field and returns it proves the store landed and
proves nothing about whether the EC acted on it.

The curve was the one lead that looked *verifiable*, because `WMBC 0x68` can
read a point back. But `XFN1` is itself an EC-populated field, so the
verification channel is dead for the same reason the control channel is. The
only mechanism that could have been confirmed is confirmed inert.

**Four mechanisms, all rejected:**

| Method | Why it fails |
|---|---|
| `0x6A` `ADJF` | one bit; cannot carry a duty |
| `0x70` `FAN1`/`FAN2` | written and ignored; a 100 % target *stopped* both fans |
| `0x46`/`0x47` `FDTY`/`GDTY` | `FDTY` is the EC's output, not an input |
| `0x68` `XFNW` | store lands, EC inert, `XFN1` never populates |

**The packing question is moot but was reasoned out anyway**, and worth keeping:
the field widths decompose as 24 = 8-bit index + 16-bit payload, `XFNR` is the
8-bit index and `XFN1` the 16-bit payload, which matches CWH's "index,
temperature, duty" and matches what `fan_curve_data_store()` already builds.
~~The packing this file called "a guess" was correct.~~ **That overclaims, and
the overclaim matters because it is the kind that outlives its evidence.** What
holds is that the packing is *consistent* with the field widths and with CWH's
stated layout — and CWH's own write-up says no value in it was ever sent to
hardware. It cannot be *validated* here at all: `XFN1` never populates, so the
read-back channel that was the whole point is dead. Consistent, not confirmed.
It simply has nothing to drive either way.

**So writable PWM is unreachable on this EC and the nodes stay read-only.** This
also corroborates GigaMate's report that the indexed store is inert on an
AERO X16 — now independently confirmed on `GA65TH`, on AMD.

One residual uncertainty, stated rather than chased: GCC on CWH reportedly sends
8 × `0x68` for its Custom mode, so either that generation's EC implements what
ours does not, or GCC's sequence has a commit step the static analysis did not
capture, or it is inert there too and nobody checked — the CWH write-up is
explicit that **no value in it was ever sent to hardware**. Settling that needs a
capture of GCC's real WMI traffic on a CWH, which is not work this project can
do. Do not re-run the duty experiments without such a capture; four mechanisms
and a dead verification channel is enough.

### A third-party CWH analysis names the `XFNW` fields

[`benedikthth/gigabyte-a16-linux-power`](https://github.com/benedikthth/gigabyte-a16-linux-power)
documents how GIGABYTE Control Center drives fans and GPU power, reverse
engineered from the GCC binaries plus a DSDT. **Three caveats before using any
of it:**

- **It is a GAMING A16 `CWH` — Intel, RTX 5070.** The generation this repo's
  own rules call "different gen, different vendor CPU". Method analysis
  transfers as a starting point; numbers do not.
- **"Status: static analysis only. No value in this document was sent to the
  hardware."** Their words. Nothing in it is hardware-validated by anyone.
- **It carries no licence**, so it is all rights reserved. Use the facts, cite
  the source, and do not copy its text or files into this repo — which matters
  for work headed upstream.

**What was checked against `GAMING-A16-5TH-DSDT.dsl` and holds on our AMD
firmware**, method body for method body:

| ID | Their description | Confirmed here |
|---|---|---|
| `0x68` set | `XFNW = Arg2`, **24 bits: index, temperature, duty** | `XFNW, 24` |
| `0x68` get | `XFNR = Arg2`, 100 ms, return `XFN1` | `XFNR, 8`, `XFN1, 16` |
| `0x57` | `GFAN = 0`, `CRAF = Arg2` — GCC's **quiet mode** | `CRAF, 1`, read/write |
| `0x66` | `FLVL = Arg2`, the current fan step | ✓ |
| `0x67` | `TENF = Arg2` | ✓ |
| `0x6A` | `ADJF = Arg2` | ✓ |
| `0x6B` | `FAN1 = Arg2`, CPU fixed duty | ✓ |
| `0x47` | `GDTY = Arg2`, `FAN2 = Arg2` | ✓ |
| `0x71` | `GFAN = 0`, `FANB = Arg2` | ✓ |
| `0x70` | `TFAN = 0`, `GFAN = 1`, `FAN1 = FAN2 = Arg2` | ✓ |

**The packing is the valuable part.** `XFNW` is index / temperature / duty, so
`data << 8 | index` packs two values into a three-field register. **Still
unvalidated, and now unvalidatable on this unit** — a stated layout rather than a
guess, but the read-back channel it would have been tested through is inert; see
"The packing question is moot" above.

**The second finding is that fan mode is four independent bits, and GCC sets
all four on every switch.** `CRAF` (`0x57`), `FANB` (`0x71`), `TENF` (`0x67`),
`ADJF` (`0x6A`) — on CWH all four live in one EC byte. Their recorded recipes:

| GCC mode | `0x6A` ADJF | `0x67` TENF | `0x71` FANB | `0x57` CRAF | also |
|---|---|---|---|---|---|
| Silent | 0 | 0 | 0 | **1** | |
| Balance | 0 | 0 | 0 | 0 | |
| Performance | 0 | 0 | **1** | 0 | |
| Max | **1** | **1** | 0 | 0 | `0x6B`=229, `0x47`=229 |
| Custom | 0 | **1** | 0 | 0 | then **8 × `0x68`** |

Four consequences for Step 4:

- ~~**`CRAF` had never been mentioned in this file and has never been tried.**~~
  **Both halves were false the moment they were written**, by the same commit
  that added the `0x57` row to "Method IDs we are not using yet" 2000 lines
  above. `CRAF` *is* the driver's `FAN_SILENT_MODE` and reads `1` whenever
  `fan_mode` is 1, so it has been driven all along; the CWH analysis named a
  field this file had left anonymous rather than finding a new control. See
  "Open decisions". **What is genuinely untried is the four-flag combination** —
  setting `CRAF`/`FANB`/`TENF`/`ADJF` together the way GCC does, rather than
  one flag at a time. It is present and read/write on our firmware.
- **The rejected `0x46`/`0x47` test wrote the wrong CPU register.** GCC sets CPU
  duty with `0x6B` → `FAN1`, never `0x46` → `FDTY`, which independently
  confirms the conclusion above that `FDTY` is the EC's output.
- **Max mode sets `TENF` *and* `ADJF` together**, where `fan_turbo` latches duty
  plus `ADJF` alone. And GCC's Max duty is **229** — exactly `FAN_DUTY_MAX`,
  arrived at independently.
- **Custom mode sends 8 curve points, not 15.** "15-point" had been used in this
  file without a source. The enumeration settled the count question in the only
  way it could: **all 16 indices `0`–`15` read back as implemented and empty**,
  so the read side accepts at least 16 indices and the firmware populates none
  of them. The count is academic now that the mechanism is closed.

**Also worth knowing, outside Step 4:**

- `0x51` is `SetNvPowerConfig`: `0` sets `NPCF.ACBT = 0`, `1` restores
  `ACBT = LCBT`, both with `Notify (NPCF, 0xC0)`. So `gpu_boost` sits on the
  **same NPCF path** already closed as firmware-blocked, which tightens that
  conclusion rather than reopening it. Reported, not verified here.
- Their `0xED` NPCF tables (`ATPP`/`ACBT`/`AMAT` in ⅛ W units, mode 2 → 85 W)
  corroborate the decoded chain `0xED` → NPCF → `Notify 0xC0` → `nvidia-powerd`
  exactly. The **values are RTX 5070 SKU-class guesses and untested**; this unit
  is a 5050. Do not import them.
- `SKUN()` reads **EC command `0xD8`** and returns the GPU SKU class. Readable,
  and it would settle which NPCF table applies.
- **Nothing on RGB.** No ENE, no usage page `0xFF00`, no hidraw, no report
  `0x0B`. Step 6b gains nothing from it.
- Its CPU power section is Intel RAPL via MSR `0x610`, and CPU power is out of
  scope here regardless.

**Test write methods through a debug node, not through hwmon.** ✅ **Done** —
`debug_method_write` takes `"method arg"`, performs the WMBD write on store and
reports the result on show, root-only at `0600`. `0x46`/`0x47` and the curve can
now be tried one value at a time without exposing a path a fan daemon could
drive into a fan stop.

Three things it does deliberately:

- **Refuses `0x63`.** It wants five bytes and the setter passes four, so the
  firmware would fail on the fifth *after* writing four bytes of CMOS — a
  half-written block the firmware reads at the next boot.
- **Takes `fan_lock`**, so a poke cannot land inside `set_fan_mode()`'s
  multi-step sequence. It cannot keep the cached fan state honest — nothing can,
  for an arbitrary write — so rewrite `fan_mode` or `fan_preset` afterwards.
- **Reports the reply rather than interpreting it.** A buffer back means
  *either* a case that assigned its field and fell through without a `Return`,
  *or* `Default { Return (Arg2) }` echoing the argument because there is no case
  for that ID — the two are indistinguishable here, so the node says so and
  points at the EC field, which is the only thing that settles it. An earlier
  version claimed "not implemented" for a buffer and was wrong on hardware.

### Step 3: profiles over fan policy — verified on hardware

Every profile was written directly to the aggregate, after the quieter mapping
landed:

```
$ cat /sys/class/platform-profile/*/name    -> gigabyte_laptop
$ cat /sys/class/platform-profile/*/choices -> low-power quiet balanced performance

low-power   -> fan_mode=1   (silent)
quiet       -> fan_mode=1   (silent)
balanced    -> fan_mode=1   (silent)
performance -> fan_mode=0   (normal)
```

And the whole `tuned` chain, one profile per invocation:

```
tuned=powersave              -> platform_profile=low-power   -> fan_mode=1
tuned=balanced               -> platform_profile=balanced    -> fan_mode=1
tuned=throughput-performance -> platform_profile=performance -> fan_mode=0
```

**The chain also verified itself with no test at all.** The machine went onto
battery mid-session, `tuned` auto-switched to `powersave`, its `[acpi]` plugin
asked for `low-power|quiet`, took `low-power`, and the handler set silent. That
is the `low-power` choice being load-bearing rather than belt-and-braces.

**That route is not the one taken today**, though the end state is the same.
On battery `tuned` now selects `balanced-battery`, which `include=`s `balanced`
and so asks for `platform_profile=balanced` → `fan_mode 1` silent. So the
anecdote above no longer describes current behaviour, and `low-power` is
load-bearing for `powersave` specifically rather than for every battery
transition. Both paths land on silent, which is why this was not noticed.

**The legacy aggregate really is created by the class API.** That was the one
assumption in this design taken from kernel source rather than observation, and
it is now confirmed: registering through `devm_platform_profile_register()`
produced `/sys/firmware/acpi/platform_profile`, which is the file `tuned` writes.

**`tuned` picks it up from the next boot, automatically.**
`systemd-modules-load.service` is `Before=sysinit.target` and ran at 1.3 s,
while `tuned.service` is `After=sysinit.target`, so the module and its profile
file exist before `tuned` applies anything. Installing the handler *mid-session*
leaves them out of step, because `tuned` already tried at boot, found no file and
logged "not supported"; `tuned-adm profile <name>` re-applies.

### Step 3 design: profiles over fan policy, with PWM taking precedence

The original design — `platform_profile` over `perf_mode` + `dynamic_boost` —
became inert when GPU TGP turned out to be unreachable. Replaced with fan
policy, which works entirely inside the EC:

| Profile | `fan_mode` |
|---|---|
| `low-power` | 1 silent |
| `quiet` | 1 silent |
| `balanced` | 1 silent |
| `performance` | 0 normal |
| *(unmapped)* | 2 gaming |

**Shifted one notch quieter than the obvious mapping, on measured behaviour.**
All three power modes were tested on hardware and the EC's normal *and* gaming
curves both ramp the fans hard, so balanced joins power saver on silent and
performance takes normal.

**Gaming is deliberately unmapped.** It is the loudest preset and is reserved as
its own axis: the Mode key cycles fan presets directly rather than going through
a battery profile. Do not quietly re-attach it to a profile. That axis is the
`fan_preset` node, and it is now implemented — see "Settled: the Mode key owns
fan policy" below.

**Why both `low-power` and `quiet`.** The two consumers prefer different names.
`tuned`'s `powersave` profile asks for `low-power|quiet` and takes the first
offered, while `tuned`'s power-profiles-daemon shim translates *back* for the
desktop indicator using a map that contains only `low-power`, `balanced` and
`performance`:

```python
PLATFORM_PROFILE_MAPPING = {
    "low-power": PPD_POWER_SAVER, "balanced": PPD_BALANCED,
    "performance": PPD_PERFORMANCE,
}
```

Offering `quiet` alone left that reverse translation blind, so a profile change
arriving by any route other than `tuned` itself would not update the indicator.
Offering both fixes it.

**The chain is live end to end**: `tuned-ppd` is active and enabled, serving
`net.hadess.PowerProfiles` with `power-saver`/`balanced`/`performance`, all
`Driver: tuned`. So the desktop selector reaches `fan_mode` through
tuned-ppd → tuned profile → `[acpi]` plugin → `platform_profile` → this handler.

`perf_mode` and `dynamic_boost` stay as raw nodes, written by nothing, in case a
BIOS update makes NVPCF work.

### Settled: the Mode key owns fan policy, profiles own it only on `auto`

That precedence question is answered, because the Mode key now cycles fan
presets. The mechanism is a `fan_preset` ring, exposed as its own node and
cycled by the key:

```
auto -> silent -> normal -> gaming -> auto
```

| `fan_preset` | `fan_mode` | Who decides |
|---|---|---|
| `auto` | whatever the profile maps to | the power profile |
| `silent` | 1 | pinned |
| `normal` | 0 | pinned |
| `gaming` | 2 | pinned |

Three rules make it unambiguous:

- **Anything but `auto` outranks a profile.** `gigabyte_laptop_profile_set()`
  records the profile and leaves the fans alone, so a profile switch can no
  longer reclaim the fans from gaming. That is the decision this section was
  waiting for, taken in the user's favour: a deliberate gaming selection
  survives `tuned` switching profiles on an AC transition.
- **`auto` re-tethers immediately**, applying the current profile's mode, but
  still defers while `fan_mode > 2` — a custom curve outranks both.
- **A direct `fan_mode` write moves the preset with it**, since it is just as
  deliberate: 0/1/2 set the matching preset, and the custom modes set `auto`,
  where the `fan_mode > 2` rule protects them instead. So the node cannot
  report a preset that is not actually in effect.

The preset ring is driver state, not firmware state, so it starts at `auto` on
every load — `FAN_PRESET_AUTO` is zero and comes free from the `kzalloc`.

**The Mode key no longer reports a keycode.** It was `KEY_PROG2`; it is now
intercepted in `gigabyte_laptop_wmi_notify()` before the keymap is consulted,
because the kernel acts on it. Two consequences:

- **A desktop binding on `KEY_PROG2` for this key stops firing.** Anyone who
  bound it as a stopgap should unbind it.
- `sysfs_notify()` fires on `fan_preset` as it changes, so a desktop can
  `poll()` the attribute for an OSD instead. The kernel log also names the new
  preset.

GiMate keeps `KEY_PROG1`, so it stays bindable.

`platform_profile_cycle()` is therefore **not** used, and should not be: it
would give the key the three battery profiles, which is the opposite of what
this is for.

**Verified on hardware**, 22 Oct 2026, on the installed build:

```
$ journalctl -k | grep "Mode key"
gigabyte_laptop: Mode key: fan preset normal

$ cat fan_preset   -> normal
$ cat fan_mode     -> 0          (normal, as the preset says)
$ cat platform_profile -> balanced
```

Note the last line: the profile reads `balanced`, which maps to silent, yet the
fans are on normal. That is the precedence rule working — the preset is pinned,
so the profile is recorded and not applied.

The notification channel is `sysfs_notify()` on `fan_preset`, plus the
`pr_info` above. There is no D-Bus or uevent signal; a desktop OSD would
`poll()` the attribute. `platform_profile_notify()` is deliberately not called,
because the profile has not changed — only which axis is in charge of the fans.

**Precedence rule, so profiles and CoolerControl do not fight.** The hwmon ABI
carries the state, and this driver maps it from `fan_mode`:

| `fan_mode` | `pwm_enable` | Meaning |
|---|---|---|
| 5 fixed | `0` | full speed — ADJF is one bit, so it is not a duty |
| 4 auto-max | `1` | userspace holds both fans at a duty |
| 0–3 | `2` | an EC curve driven from temperature |

So **anything the user set deliberately wins while it is active.** The test in
`gigabyte_laptop_profile_set()` is `fan_mode > 2`, which covers the custom
curve (3) as well as the two `pwm_enable != 2` states: a profile switch records
the profile but leaves fan policy alone, and applies it on the next switch once
the fans are back on an EC preset. Nothing yanks the fans out from under a
running fan curve.

### Step 2 validation

The read-only half is **done, and both DSDT predictions held**. Sentinel reads
with argument `0x5A`:

```
method 0xed arg 0x5a -> 0x5a (90) [echoed argument: method not implemented]
method 0xe7 arg 0x5a -> 0x0 (0)
```

**That sample is in the node's _old_ wording.** `debug_method` was later
given the typed read, and the same call now prints
`[not implemented: reply was not an integer] [argument echoed back]`. The
reading is unchanged -- see the bracket-matching note under "WMBC echoes
unknown method IDs" for why the two strings are not interchangeable when
parsed.

`0xED` echoes the sentinel, confirming on this machine's firmware that
performance mode is write-only exactly as the ASL said. `0xE7` does not echo,
so dynamic boost really is implemented here, and it currently reads `0` — off.
That also validates the sentinel technique itself: the two cases are now
distinguishable, which they were not before Step 1b.

### Ending turbo by changing the fan mode — validated on hardware

Separate from `fan_turbo 0`, and the path `end_fan_turbo()` exists for. With
`fan_custom_speed` at **100** beforehand:

```
echo 1 > fan_turbo     # fans to full
echo 4 > fan_mode      # ends turbo through the mode change
fan_custom_speed -> 100   (not 229)
fan_turbo        -> 0
```

The duty came back rather than staying at `FAN_DUTY_MAX`. That mattered
specifically for **mode 4**, auto-maximum, which programs the fans straight
from `fan_custom_speed` — so before the fix, asking for mode 4 while turbo was
on silently inherited turbo's duty. Modes 0-2 ignore the duty and hid the bug.

The run also produced `Could not clear the turbo fan bit`, which turned out to
be the void-WMBD problem above rather than a real failure. The clear had
worked.

### `0x7D` is readable — and the sentinel read that proved it

Sentinel read on the installed build:

```
method 0x7d arg 0x5a -> 0x0 (0)
```

No echo, so **`WMBC 0x7D` is implemented** and `EC0.TFAN` currently reads `0`.
That independently confirms the void-WMBD diagnosis above: the clear that logged
"Could not clear the turbo fan bit" had in fact landed.

### Settled: `TFAN` alone does **not** hold the fans — the latch stays

Tested with `debug_method_write`, which is what it was built for. Starting from
`fan_mode 1`, `fan_custom_speed 100`, fans idling:

```
echo '0x7D 1' > debug_method_write     -> reported "not implemented" (that bug, since fixed)
sensors                                -> fan1 1666 RPM  fan2 1666 RPM   ** unchanged **
echo '0x7D 0x5A' > debug_method        -> method 0x7d arg 0x5a -> 0x1 (1)
```

So the bit **was set** — `WMBC 0x7D` reads `EC0.TFAN` back as `1` — and the fans
did not move. Two conclusions:

- **`fan_turbo`'s duty-plus-fixed-mode latch is necessary and stays.** The fork
  was right that writing the bit alone does not reach the fans, and right for
  the right reason, not by accident. `end_fan_turbo()`, the duty save/restore
  and the two-step mode restore all keep their justification.
- **`TFAN` is a status bit, not a control.** It presumably tells the EC's own
  firmware that turbo is wanted, and something else — the duty, the `ADJF`
  latch — is what actually drives the fans. Writing it has no observable effect
  on its own.

The same run is what disproved the buffer-means-unimplemented theory above, so
this one test settled two questions.

**Put it back after testing**, since the driver does not know the bit moved:

```sh
S=/sys/devices/platform/gigabyte_laptop
echo '0x7D 0' | sudo tee $S/debug_method_write
echo '0x7D 0x5A' | sudo tee $S/debug_method && sudo cat $S/debug_method   # expect 0x0
echo 1 | sudo tee $S/fan_mode                                             # resync the cache
```

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

`perf_mode` 0/1/2 leaves `enforced.power.limit` at **30 W** throughout (22 Oct
2026; see the AC/DC caveat below), with the GPU at `P8`. That is *not* evidence
the method does nothing. The chain is:

> **Every power figure in this section is un-annotated for AC/DC, and that is a
> real defect in the record** — the firmware branches on `EC0.ACST` and programs
> different limits on each. The 30 W readings here were taken on 22 Oct 2026
> with the AC/DC state unrecorded; on **24 Oct 2026, on battery**, the same
> query reads **40 W** against the same 50 W default and 85 W maximum. Whether
> 40 W is this machine's DC figure or a figure that has simply moved since
> cannot be told from what was written down. **The section's conclusion is
> unaffected** and must not be reopened on this: 40 W still sits below the 50 W
> VBIOS default, so "capped, not idle" holds, and `nvidia-smi -pl` is still
> refused outright. One sentence does break; it is marked below.

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

`enforced.power.limit` still read 30 W against a 50 W default. The cleanup was
worth doing regardless — both arguments were dead weight — but it was not the
cause. Do not re-litigate this one.

~~**A gap in the test itself, before blaming firmware.** Every reading so far
was taken with the dGPU at `P8` and drawing 3–5 W. On NVIDIA laptops
`enforced.power.limit` reflects the *currently arbitrated* limit, which at idle
can sit at a floor that no mode selection will move. The sweep has never been
run with the GPU actually busy, so "`perf_mode` changes nothing" is not yet
supported. Drive the dGPU with `__NV_PRIME_RENDER_OFFLOAD=1`, confirm the
P-state leaves `P8`, and only then compare across modes.~~

~~**`gpu_boost` (`0x51`) has never been written.** It is the other GPU lever
this firmware offers, `WMBD`-only, and the fork reports it takes 0 or 1 on
Gaming models. It should be swept alongside `perf_mode` before concluding
anything.~~

**Both of those to-dos are refuted by the paragraph immediately below, not
merely stale**, which is why they are struck rather than left to be read. The
load test is named a red herring there by the very next heading, and `0x51` was
since decoded: it writes `NPCF.ACBT` and fires the same `Notify (NPCF, 0xC0)`
that cannot be serviced, so sweeping it cannot produce a different answer than
`perf_mode`'s. They are kept because the reasoning that made each look
worthwhile is the reason the refutation is worth having.

**Read the limit with `enforced.power.limit`.** `power.limit` returns `[N/A]`
on this driver — it maps to "Requested Power Limit". The useful numbers are
`enforced.power.limit` **30 W (22 Oct, AC/DC unrecorded) / 40 W (24 Oct, on
DC)**, `power.default_limit` 50 W, `power.max_limit` 85 W. ~~Which matches the
30/50/85 the three modes are expected to select.~~ **That argument is gone**: it
rested entirely on the enforced value happening to equal the eco-mode figure,
and at 40 W the coincidence does not exist. The three-mode correspondence was
never evidence of anything, which is worth saying plainly — an arbitrated limit
that lands on one of the table's numbers is a coincidence, not a reading of the
table.

**The load test was a red herring, and GPU TGP is closed.** A power limit is a
setting, not a measurement, so if `perf_mode` moved it the change would show at
idle too. And the enforced limit sits *below* the 50 W VBIOS default — 30 W
then, 40 W now — which is not what Dynamic Boost arbitration looks like:
arbitration raises above base rather than pinning under it. That pattern means
capped, not idle, and it means the same at either figure.

Confirmed by trying to set it directly:

```
$ sudo nvidia-smi -pl 85
Changing power management limit is not supported in current scope for GPU: 00000000:01:00.0.
$ nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader
30.00 W                       # 40.00 W when re-read on DC, 24 Oct 2026
```

Rejected for 85, 50 and 30 alike. On laptop GPUs the platform owns TGP through
NVPCF, which is why the driver refuses manual changes — and the platform
interface is the thing that is broken, so nobody can set it. Both routes are
shut:

| Route | Result |
|---|---|
| `perf_mode` → NPCF → `nvidia-powerd` | daemon cannot initialise; SBIOS withholds the power-limit table |
| `nvidia-smi -pl` | refused, "not supported in current scope" |

**GPU TGP and dynamic boost — "D3" and "D4" in an earlier numbering this file
never defined — are closed as blocked by firmware, not by this driver.** The WMI
write lands, the AML executes, the notify arrives; the consumer above us is
broken on BIOS FB03 with the 615.78.08 open kernel module. Nothing in
`gigabyte-laptop.c` can change that. Revisit only if a BIOS or driver update
makes `nvidia-powerd` start cleanly — the one-line check is
`journalctl -u nvidia-powerd -b | head`.

**Consequence for Step 3 — resolved.** The original design was "a profile
switch sets `perf_mode` and `dynamic_boost` only, fan settings deliberately
left alone". That rationale assumed `perf_mode` did something; with TGP
unreachable a profile built on it would have done nothing at all. The design
was therefore rewritten over **fan policy**, shipped, and verified on hardware
— see "Step 3 design: profiles over fan policy, with PWM taking precedence".
No longer an open question.

### `perf_mode` has a second half, and it has never been tested — 24 Oct 2026

**The most valuable finding of the firmware audit, and this file did not record
it at all.** `0xED` was decoded here only as `→ NPCF.ATPP etc. →
Notify (NPCF, 0xC0)`, and the whole method was then closed as firmware-blocked
on the strength of the GPU consumer being broken. That decoding was incomplete.

**Every mode branch also issues three `ECPT()` calls**, and `ECPT` has nothing
to do with NPCF. `GAMING-A16-5TH-DSDT.dsl:9176` shows it converting watts to
milliwatts (`Arg1 * 0x03E8`) and issuing two six-byte EC commands with command
byte `0x45` through the `ERCD` mailbox — a raw EC write that never reaches
`nvidia-powerd` and does not depend on it. Indices `0x30`/`0x32`/`0x34` at these
magnitudes are the shape of APU SPL / sPPT / fPPT.

On AC (`EC0.ACST == One`), per mode:

| `perf_mode` | `ECPT 0x30` | `ECPT 0x32` | `ECPT 0x34` |
|---|---|---|---|
| 0 | 45 W | 65 W | 65 W |
| 1 | 65 W | 65 W | 80 W |
| 2 | 70 W | 80 W | 80 W |

On battery the ladder flattens — mode 0 is 45/45/45 and mode 1 is 65/65/65 —
which is incidentally why every power figure in this file needs an AC/DC
annotation.

**So "`perf_mode` does nothing" was only ever tested on the GPU side.** The
GPU-TGP conclusion is untouched and must not be reopened: that chain is broken
above the driver, independently, and this is a *different* chain that happens to
share a method ID. What follows is narrower and more interesting — the APU-power
half has never been measured at all, and it is the **highest-value remaining
experiment in the project** because it needs no reverse engineering and no new
code.

**How to test it.** On AC, pin cooling first (`echo gaming > fan_preset`), run a
sustained all-core load, and sweep `perf_mode` 0 → 1 → 2 recording steady-state
package power and all-core clock at each step. A 45 → 65 → 70 W sustained ladder
confirms it; a flat curve closes it. Note the usual caveat in its sharpest form
here: `ECPT` goes through `ERCD`, so a successful write proves the mailbox
transaction completed and proves nothing about what the EC did with it. Only the
sustained clock settles it.

### `perf_mode` value 3 exists in this firmware; the node caps at 2

The driver rejects `mode > 2` (`gigabyte-laptop.c`: "Invalid performance mode")
and its comment documents 0 eco / 1 balanced / 2 boost. This firmware implements
a **fourth fully-populated mode**, and it is not a duplicate of mode 2: mode 2
reads a runtime power class with `Local0 = ECPL ()` and switches `ATPP` on the
result, where **mode 3 pins `ATPP = 0xC8`** outright, with `ACBT = 0xA0`,
`AMAT = 0x78` and the mode-2 `ECPT` ladder. `If ((Local1 == 0x04)){}` and
`If ((Local1 == 0x05)){}` follow it with **empty bodies**, so **0–3 is the real
range** and the cap is one short rather than arbitrary.

Try it through `debug_method_write` (`echo '0xED 3'`) during the sweep above,
not by raising the sysfs range check first. If mode 3 behaves, raise the check
to 3 and correct the node's comment block; if it does not, record 0–2 as the
real range *with* the firmware reason, which is what is missing today.

### `dynamic_boost` round-trips, direction still unknown

`0 -> 1 -> 0` reads back correctly, so the node and the inversion are right.
Which direction means "boost on" cannot be settled while the TGP is pinned, so
**dynamic boost is blocked on the same thing** as GPU TGP.

The firmware does give the sweep above a second observable it did not have
before. `Case (0xE7)` writes `EC0.PPAB` as well as the NPCF fields — write 0
zeroes `AMAT` and clears `PPAB`, write 1 restores `AMAT` from the value `0xED`
cached and sets `PPAB` — and `PPAB` is a 1-bit EC field that every `perf_mode`
branch also sets. So toggling `dynamic_boost` at each `perf_mode` step and
watching sustained package power costs nothing extra once the APU sweep is being
run, and it is the only route to the direction question that does not go through
`nvidia-powerd`.

### Other

- **No Windows dual-boot on this machine.** A Windows USB install is available
  as a later option if Step 6 needs GiMate traffic captured. Until then, RGB
  work means blind-probing report `0x0B`, where GigaMate's firmware-hang
  warning applies.
- CPU power management is out of scope. `amd-pstate-epp` with `dynamic_epp` and
  `prefcore` already works; this driver must not touch it. ~~The gap is GPU TGP
  and fan policy.~~ **Both of those closed**: fan policy shipped as the
  `platform_profile` handler plus the `fan_preset` ring, and GPU TGP is
  firmware-blocked. The gap now is the **APU package power** that `0xED` writes
  through `ECPT` — which is adjacent to CPU power management but is a
  platform/EC limit rather than a governor setting, so it does not conflict with
  leaving `amd-pstate-epp` alone.

## Root-only diagnostics — both done

**Nothing here is pending.** This section used to be the last thing in the file
and read as a to-do list, which is the worst possible place for one that is
already complete. Kept because the hygiene note in the first item is worth
having the next time a dump is taken.

~~Dump every table and decompile all of them~~ — **done; the output is
committed.** `GAMING-A16-5TH-DSDT.dsl` and `GAMING-A16-5TH-SSDT12-APMF.dsl` came
from this run, which is where `AMDI0100` and the APMF methods were found, and
they are analysed at length under "Firmware reference" and "amd_pmf is one
kernel parameter away from binding". It needed a password, so it could not run
from a non-interactive shell. The command, for the next time:

```sh
# acpidump -b writes into the current directory and runs as root, so do it in a
# scratch directory -- never in the checkout, or the repo fills with root-owned
# .dat and .dsl files. Commit only the tables needed; see "Only commit the
# tables you need".
d=$(mktemp -d) && cd "$d" && sudo acpidump -b && iasl -d dsdt.dat ssdt*.dat
```

~~Live capture on the ECSH vendor pipe~~ — **done, and the answer was no.**
`sudo timeout 20 cat /dev/hidraw2 | xxd` over a window with GiMate and Fn+F7
pressed produced **no bytes**, and the instrumented build then showed both keys
arriving over WMI. Step 5 shipped on the WMI path and needs nothing from
`hidraw2`; the pipe is only relevant to the RGB work in Step 6.
