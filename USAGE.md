# Usage

**DISCLAIMER:** I recommend reading this entire document so you are able to use this kernel driver correctly. Incorrect usage may damage your machine.

## Where are the nodes?

All available nodes are found at the following path:

```text
/sys/devices/platform/gigabyte_laptop
```

You can write to these nodes using `echo` and `tee`. Keep in mind that you must be logged in as `root` or using `sudo` for this.

## Fan modes

Aero/AORUS laptops currently support six fan modes. They are implemented in the kernel driver and recognized in the following order, starting from zero:

- Normal mode
- Silent mode
- Gaming mode
- Custom mode
- Auto mode
- Fixed mode

The last two modes will enable custom mode automatically, as they are considered "custom modes". Custom mode will be automatically disabled if the first three modes are enabled.

**Node:** `/sys/devices/platform/gigabyte_laptop/fan_mode`

**Example:** To switch to gaming fan mode:

```sh
echo '2' | sudo tee /sys/devices/platform/gigabyte_laptop/fan_mode
```

## Fan preset

The fan preset decides *what* chooses the fan mode. It takes a name:

| Value | Effect |
|---|---|
| `auto` | the power profile chooses, which is the default |
| `silent` | pin silent (`fan_mode` 1) |
| `normal` | pin normal (`fan_mode` 0) |
| `gaming` | pin gaming (`fan_mode` 2) |

While the preset is anything other than `auto`, a power profile change is
remembered but does not touch the fans. Selecting `auto` again hands the decision
back to the profile.

`auto` applies the profile **immediately only while the fan mode is 0, 1 or 2**.
Above that — the custom curve, a held duty, or full speed — it defers instead,
leaving the fans where they are, because those are deliberate states that
outrank a policy selection. The profile then takes effect on the next switch
once the fans are back on one of the three embedded-controller presets.

**No power profile maps to gaming mode**, because it is the loudest preset and
does not belong on a battery profile. Select it through this node, with the Mode
key, or by writing `fan_mode` directly.

**Node:** `/sys/devices/platform/gigabyte_laptop/fan_preset`

**Example:** To pin gaming fan mode:

```sh
echo 'gaming' | sudo tee /sys/devices/platform/gigabyte_laptop/fan_preset
```

Writing `fan_mode` directly moves the preset with it, since a direct write is
just as deliberate: `fan_mode` 0, 1 and 2 set the matching preset, and the
custom modes set `auto`, where they are protected by the rule below instead.

### The Mode key

On models whose Mode key arrives as a WMI event (Fn+F7 on the Gigabyte Gaming
A16), the driver cycles this node when the key is pressed:

```
auto -> silent -> normal -> gaming -> auto
```

The key reports no keycode, because the kernel acts on it. The driver raises a
sysfs notification on `fan_preset` as it changes, so a desktop can `poll()` the
attribute and show the new preset. The kernel log also names it:

```
gigabyte_laptop: Mode key: fan preset gaming
```

### Desktop notifications for the Mode key

`tools/gigabyte-fan-preset-notify` puts a toast on screen when the key changes
the preset. It is a small C program — about 150 lines with comments — that
`poll()`s the `fan_preset` attribute and runs `notify-send`.

```sh
cd tools && make && sudo make install
systemctl --user enable --now gigabyte-fan-preset-notify.path
```

**Enable the `.path` unit, not the service.** The path unit starts the watcher
when the driver's attribute appears, which the service alone would not do at
login.

**It does not restart the watcher after a module reload, and no unit
dependency can.** Measured 24 Oct 2026: the watcher survives a reload holding
an orphaned file descriptor. `systemctl --user is-active` reads `active`
throughout, `NRestarts` stays `0`, and every Mode key press is missed. The
driver side is unaffected — it logs each press — so only the toasts go quiet,
with nothing reporting it.

The reason no unit can fix it is the same for both candidates. `PathExists=`
and a udev `SYSTEMD_USER_WANTS=` both enqueue a **start** job, and a start
against an already-active unit is a no-op. Verified directly: issuing
`systemctl --user start` against the running watcher returned 0 and left the
PID unchanged.

**So the watcher recovers itself**, with a periodic liveness check: `poll()`
takes a finite timeout, and on each idle wake a read probes the descriptor.
kernfs fails a read on a removed node while the fd, the path and `poll()` all
still look healthy, so the read is the only thing that detects it. On failure
the watcher re-opens the attribute and re-arms. Toasts resume within the poll
interval, with no second activation path and no udev rule.

**Diagnose a suspected stale descriptor by inode**, never by unit state, which
reads `active` either way:

```sh
PID=$(systemctl --user show -p MainPID --value gigabyte-fan-preset-notify.service)
stat -c %i /sys/devices/platform/gigabyte_laptop/fan_preset   # the live node
for f in /proc/$PID/fd/*; do                                  # what it holds
	case "$(readlink $f)" in *fan_preset*) stat -L -c %i "$f";; esac
done
```

**Match on the symlink target, not on `fd/3`.** Recovery opens the replacement
before closing the old descriptor, so the number moves — and it **alternates
rather than climbing**. The replacement takes the lowest free number while the
old one is still held, then the old number is released and is the one reused on
the next recovery. The sequence is 3 -> 4 -> 3 -> 4. Exactly one is ever open.

Equal is healthy. If they differ on a build that predates the self-healing
watcher, recover with `restart` — **not `start`**, which is the no-op above:

```sh
systemctl --user restart gigabyte-fan-preset-notify.service
```

It needs no privileges, allocates nothing, and uses 1.3 MB of memory sitting
blocked in `poll()` at zero CPU.

Two things about it are worth knowing, because both are easy to get wrong:

- **The attribute has to be read once before `poll()` will block.** Until the
  event counter is consumed, `poll()` returns immediately and a loop around it
  spins at 100% CPU. The first read also gives the current preset, which is
  recorded rather than announced, since it is state and not a change.
- **The uevent is not the route to a notification.** The driver emits one for
  the same change, but a udev rule runs as root in `systemd-udevd`, outside the
  session, with no bus to post on. A notification has to come from something
  running in the session, which is what this is.

It reacts to the **key** only. Writing `fan_preset` or `fan_mode` from a script
does not raise the notification, because the driver does not notify on a write —
the caller of a write already knows what it did.

## Custom fan speed

Aero/AORUS laptops support setting a custom fan speed. However, this only takes effect if either auto or fixed mode is enabled.

As of version 0.2.0, the accepted range is 0-255. Earlier versions require fulfilling the following conditions:

- The number between 25 and 100.
- The number is divisible by 5.

**Node:** `/sys/devices/platform/gigabyte_laptop/fan_custom_speed`

**Example:** To set the custom fan speed to 50 percent:

```sh
# Version 0.2.0+
echo '128' | sudo tee /sys/devices/platform/gigabyte_laptop/fan_custom_speed
# Before version 0.2.0
echo '50' | sudo tee /sys/devices/platform/gigabyte_laptop/fan_custom_speed
```

**Caution on Gigabyte Gaming (2025+) firmware: the scale here is unresolved.**
The driver passes this value to the controller **unconverted** — that much is
plain in the code — while the PWM read path treats the controller's duty scale
as percent, which is what `fan_pwm` reports and what hwmon `pwm1` converts from.
The two halves therefore disagree.

In practice it makes no difference to fan speed on this generation, because
**the controller does not act on this value proportionally at all.** It reaches
the hardware by two routes and neither is a duty: auto mode hands it to a method
the controller ignores, and turbo reaches full speed through a single-bit flag
rather than through the number. So treat this node as having no reliable
proportional effect here, whatever scale it is read on, and do not rely on a
value as a percentage of fan speed.

## Charging mode

**Disclaimer:** Charging mode (and limit) is not supported on the following models:

- [Aero 14-W/K](https://www.gigabyte.com/Laptop/AERO-14--GTX-970M-965M)
- [Aero 14-W6](https://www.gigabyte.com/Laptop/AERO-14--GTX-1060)
- [Aero 14-W7](https://www.gigabyte.com/Laptop/AERO-14--i7-7700HQ)

Aero/AORUS laptops support two charging modes: Normal (0) and custom (1). The custom charging mode simply stops the laptop from passing its charging limit.

**Node:** `/sys/devices/platform/gigabyte_laptop/charge_mode`

**Write the limit before the mode.** Enabling custom charging latches whatever
ceiling the EC already holds, so the driver refuses to enable it while that
ceiling is 0 or out of range, and says so in the kernel log. On at least one
machine the ceiling has read back as 0 after a power cycle, and enabling on top
of that would ask the EC to stop charging at 0 %.

## Charging limit

Aero/AORUS laptops support a charging limit. Charging mode must be set to custom for it to take effect. It will only accept numbers between 60 and 100.

**Node:** `/sys/devices/platform/gigabyte_laptop/charge_limit`

**Example:** To set the charging limit to 80 percent:

```text
echo '80' | sudo tee /sys/devices/platform/gigabyte_laptop/charge_limit
```

## Charge threshold (the standard ABI)

The charge ceiling is also exposed where the rest of Linux looks for it:

```text
/sys/class/power_supply/BAT*/charge_control_end_threshold
```

That is the standard attribute `upower` reads and TLP writes, so a desktop or
power-management tool that understands charge limits will find it without
knowing anything about this driver.

```sh
# Stop charging at 80 %
echo 80  | sudo tee /sys/class/power_supply/BAT1/charge_control_end_threshold
# No limit
echo 100 | sudo tee /sys/class/power_supply/BAT1/charge_control_end_threshold
```

The firmware has **two** fields where the ABI has one number — a ceiling byte
and a separate enable bit — so the mapping is fixed and worth knowing:

| Written | Effect |
|---|---|
| `1`–`99` | sets the ceiling, then enables the mode |
| `100` or `0` | sets the ceiling to 100, then disables the mode |
| above `100` | rejected, nothing written |

Reads return `100` whenever no ceiling is in force, including when the mode is
off but the firmware still remembers a previous ceiling. Reporting a remembered
but inactive limit would be the one answer that actively misleads.

Writes always set the ceiling **before** the enable bit, because enabling the
mode latches whatever the ceiling byte already holds. That order also means a
partial failure is harmless: a ceiling with the mode off enforces nothing, and
an enable that lands on 100 enforces nothing either.

Unlike `charge_limit`, this node is not restricted to 60–100. That floor has no
basis in the firmware, and here the ABI defines the range instead.

**It coexists with `charge_mode` and `charge_limit`**, which remain the raw
view of the two fields and are what upstream exposes. All three share a lock, so
they cannot interleave, and each updates the state the others report.

## Fan curve data (added in version 0.1.0)

Aero/AORUS laptops support setting a custom fan curve. Custom fan mode must be enabled for it to take effect.

**Nodes:**

```text
/sys/devices/platform/gigabyte_laptop/fan_curve_index
/sys/devices/platform/gigabyte_laptop/fan_curve_data
```

The index node specifies which index in the fan curve can be modified, while the data node holds the temperature (in Celsius) and fan speed for that index, printed in that order (for readability). There are 255 indices available, but only 15 can be modified. This is to ensure compatibility with Gigabyte's Control Center software on dual-boot systems.

Each index should contain both temperature and fan speed in strictly non-decreasing order. The temperature can be any number between 0 and 100, and the fan speed can be any number between 0 and 255.

You must set the index node to the index you wish to modify first. The data node can only take a single 16-bit number, so you must combine your specified temperature and fan speed first, in reverse order. An easy way to do this is to multiply the fan speed by 256, and then add the temperature to the result.

**Example:** To set index 2 to half fan speed at 55 degrees Celsius:

```sh
echo '2' | sudo tee /sys/devices/platform/gigabyte_laptop/fan_curve_index
# 127*256+55 = 32512+55 = 32567
echo '32567' | sudo tee /sys/devices/platform/gigabyte_laptop/fan_curve_data
```

## Battery cycle (added in version 0.1.0)

Aero/AORUS laptops support battery cycles, but are only accessible through the embedded controller. Older models are likely to read 0 due to older Gigabyte firmware. Because there are two different battery cycle numbers, only the highest one is printed. This node is read-only.

**Node:** `/sys/devices/platform/gigabyte_laptop/battery_cycle`

**Not available on Gigabyte Gaming (2025+) firmware, and the node is not
created there.** Both method IDs this node reads are absent from that
generation. The driver asks the firmware at load time and omits the node
entirely rather than publishing one that would answer `0` forever — an absent
file means "no such feature", where a file reading `0` is indistinguishable
from a real measurement.

The count is still available: the firmware reports it by the standard route and
the kernel's own battery driver picks it up with no help from here:

```sh
cat /sys/class/power_supply/BAT1/cycle_count
```

## GPU boost (added in version 0.1.0)

**Disclaimer:** Models older than the [Aero 15 X9 Series](https://www.gigabyte.com/Laptop/AERO-15--RTX-20-Series) do not support this, as it requires NVIDIA's Dynamic Boost from their Max-Q technologies.

Aero/AORUS laptops support boosting the discrete GPU's power limit. Even though this is controlled by `nvidia-powerd`, the embedded controller can control this as well.

Laptops with RTX 3000 series GPUs or newer have three different modes, while older models have one.

**On Gigabyte Gaming (2025+) firmware this node does more than set a boost
level.** Reading the firmware for that generation, the accepted values are:

| Value | What the firmware does |
|---|---|
| `0` | disable the NPCF boost state |
| `1` | enable it |
| `2` | **nothing — no branch exists for it** |
| `3` | **detach the discrete GPU** — an ACPI eject request the kernel services with an orderly unbind |
| `4` | restore the discrete GPU and rescan the bus |

**The driver accepts the full 0-4 range.** Values 3 and 4 are a matched
detach/restore pair rather than boost levels, and both are available.

### Detaching and restoring the discrete GPU

Value 3 is not a blunt power cut. `Notify (PEGP, 0x03)` is
`ACPI_NOTIFY_EJECT_REQUEST`, the standard signal a laptop sends when a device
is being removed, and Linux responds by **offlining the device and unbinding
its driver in order** before calling the firmware's `_EJ0`. On a GAMING A16
5TH the kernel recognises the card as ejectable and says so:

```sh
cat /sys/bus/acpi/devices/LNXVIDEO:00/path
# \_SB_.PCI0.GPP0.PEGP          <- the discrete GPU
ls  /sys/bus/acpi/devices/LNXVIDEO:00/eject
# present -- the firmware provides _EJ0
```

**The firmware enforces the interlock that matters.** The whole routine is
gated on the display MUX and runs only while the internal panel is driven by
the integrated GPU — you cannot detach the GPU that is drawing your screen,
and the firmware refuses rather than trusting the caller. Check which GPU owns
the panel with:

```sh
grep -l '^connected$' /sys/class/drm/card*-eDP-*/status
# .../card1-eDP-1/status with card1 = amdgpu -> panel on the iGPU, detach allowed
```

**What the firmware does not check is whether anything is using the GPU, and
neither does the driver** — not an oversight, but because the kernel cannot
answer it. The signals it exposes for a PCI device are "a driver is bound" and
"runtime PM says active", and both stay true for as long as the graphics
driver is loaded. A check on either would refuse every detach rather than the
unsafe ones, which would amount to removing the feature. The authority is the
graphics stack's own tooling, so **check before you detach:**

```sh
nvidia-smi          # read the Processes table at the bottom
```

**Use the plain output, not `--query-compute-apps`.** That query lists compute
contexts only, so a process using the GPU purely for graphics does not appear
in it. The `Processes` table shows both, and its `Type` column tells you which:
`C` compute, `G` graphics, `C+G` both.

**Expect your desktop to be on the list.** On a hybrid-graphics machine the
compositor itself commonly holds the discrete GPU:

```
|  GPU   GI   CI    PID   Type   Process name                  GPU Memory |
|    0   N/A  N/A  <pid>   C+G   /usr/bin/kwin_wayland               6MiB |
```

That is a measured example from a GAMING A16 5TH, and note the `C+G` — the
compositor happened to hold a compute context too, which is the only reason
the compute-only query would have caught it. A `G`-only process would have been
missed entirely.

If anything is listed, stop it first — or accept that it loses the device.
There is a real safety net below this: the kernel services the eject request
by offlining the device before removing it, and aborts if that fails, so this
is an orderly teardown rather than a surprise removal. What nothing can catch
is a driver that offlines cleanly while the programs using it do not.

```sh
echo '3' | sudo tee /sys/devices/platform/gigabyte_laptop/gpu_boost
```

The detach is logged at warning level, so `dmesg` carries a record of it.

**Restoring it**, either way works:

```sh
echo '4' | sudo tee /sys/devices/platform/gigabyte_laptop/gpu_boost
# or, if the driver is not loaded:
echo '1' | sudo tee /sys/bus/pci/rescan
```

Both the detach and the restore are logged to the kernel ring buffer, so
`dmesg | tail` shows what happened.

**If the MUX is switched to discrete**, `DPMF` becomes 2, the firmware skips
the entire routine, and *every* value of this node — including the ordinary
boost levels 0 and 1 — silently does nothing.

**Node:** `/sys/devices/platform/gigabyte_laptop/gpu_boost`

**Example:** To enable GPU boost:

```sh
echo '1' | sudo tee /sys/devices/platform/gigabyte_laptop/gpu_boost
```

## dGPU ejector presence

An informational flag, read-only. It reports whether the driver believes this
model line can detach its discrete GPU, decided from the **model name** when
the driver loads — it is not read from the firmware and nothing in the driver
gates on it.

**It does not control whether detaching works.** Detach and restore are
available through `gpu_boost` values 3 and 4 regardless of what this reads; see
"Detaching and restoring the discrete GPU" above. The interlock that actually
decides whether a detach can happen is in the firmware, which refuses while the
internal panel is driven by the discrete GPU.

**Node:** `/sys/devices/platform/gigabyte_laptop/has_dgpu_ejector`

## USB toggles (added in version 0.1.0)

Aero/AORUS laptops support USB power output when they are asleep (S3) or in hibernation (S4). Newer models have dropped the latter, and will return 0 by default. These toggles are currently read-only.

**Nodes:**

```text
/sys/devices/platform/gigabyte_laptop/usb_charge_s3_toggle
/sys/devices/platform/gigabyte_laptop/usb_charge_s4_toggle
```

**Not available on Gigabyte Gaming (2025+) firmware, and the nodes are not
created there.** Both method IDs are absent from that generation, and there is
no live controller field behind the feature either. The driver checks at load
time and omits both nodes rather than publishing toggles that always read `0`.

**It is not a driver gap — the feature is not in the firmware at all.** BIOS
setup on this generation has no USB option of any kind, so there is nothing to
enable by any route: not through this driver, not through a BIOS setting, and
not through a vendor tool. Confirmed on a `GA65TH` running BIOS FB03 by reading
the whole Peripherals menu.

## Keyboard backlight

Exposed as an **LED class device**, not as a node under the platform directory:

```text
/sys/class/leds/gigabyte_laptop::kbd_backlight/brightness
/sys/class/leds/gigabyte_laptop::kbd_backlight/max_brightness
```

That name is what the desktop already watches. `upower` matches on subsystem
`leds` with a name containing `kbd_backlight`, exports it on
`org.freedesktop.UPower.KbdBacklight`, and KDE's keyboard-brightness slider
reads it from there — so the slider works with nothing else installed. systemd's
`99-systemd.rules` matches the same name and gives save/restore across reboots
for free.

**`max_brightness` is 1 — the backlight has two levels, off and on.** That was
measured, not assumed: the firmware's `KBLL` field is eight bits wide with no
clamp anywhere, but the embedded controller publishes its own level as a WMI
event, and across repeated Fn+Space presses it only ever reports 0 or 1.

```sh
# Off, then on
echo 0 | sudo tee /sys/class/leds/gigabyte_laptop::kbd_backlight/brightness
echo 1 | sudo tee /sys/class/leds/gigabyte_laptop::kbd_backlight/brightness
```

**Fn+Space keeps working, and the driver follows it.** The key is handled inside
the embedded controller, so the level can change without the driver writing it.
Two things keep the two in step: reads go to the hardware rather than to a cached
value, and the `0xF6` event the controller sends is forwarded to the LED core, so
`brightness_hw_changed` fires and the desktop's slider tracks the key.

The node appears only if the firmware implements method `0xF6`; on models that do
not, the driver logs `Keyboard backlight unsupported by this firmware` and the
LED is absent rather than present and inert.

If the slider does not appear after loading the module mid-session, restart
`upower` — it coldplugs LEDs at startup. From the next boot the ordering is
right by construction.

To check that `upower` has picked it up, call the interface rather than reading
`NativePath`, which `upower` leaves empty for this object:

```sh
busctl --system call org.freedesktop.UPower /org/freedesktop/UPower/KbdBacklight \
    org.freedesktop.UPower.KbdBacklight GetMaxBrightness
# i 1   <- found it; 0 means it did not
```

## Power on time (added in version 0.2.0)

Aero/AORUS laptops support "power on time", though its use is unknown. This node is read-only.

**On Gigabyte Gaming (2025+) firmware the name is wrong.** The method behind
this node returns no timestamp there. It returns five bytes of extended CMOS
settings storage — the same five the matching setter writes — and their contents
are not stable from one session to the next. Do not read a value here as a
running total of anything.

**Node:** `/sys/devices/platform/gigabyte_laptop/power_on_time`

## Light sensor (added in version 0.2.0)

Aero/AORUS laptops support light sensors, but it's only equipped on some models. If no light sensor is installed, it will simply return `0` by default. This node is read-only.

All VE and newer models (e.g. Aero 16 XE5) return four 8-bit values, while older models (e.g. Aero 15 VD) return a single 32-bit value. To calculate the sensor value on newer models, ignore the first value and combine the last three in reverse order using bit shift.

```text
# Format: 247 [low] [medium] [high]
# Actual value (bit shift): [high] << 16 | [medium] << 8 | [low]
# Actual value (arithmetic): [high]*65536 + [medium]*256 + [low]
```

**Node:** `/sys/devices/platform/gigabyte_laptop/light_sensor`

**Not available on Gigabyte Gaming (2025+) firmware, and the node is not
created there.** This is not merely unimplemented in the driver: both method
IDs are absent from that generation, and so is every standard route — no ACPI
ambient-light device is declared at all. The sensor is not fitted.

The driver tests both methods at load time and omits the node when neither
answers. The two need different tests, which is worth knowing if you are
reading the code: the newer method replies with a buffer whose first byte is a
`0xF7` marker, and a buffer is also what an *absent* method replies with, so
only the marker separates them.

## PWM (added in version 0.2.0)

**Disclaimers:**

- Models older than the [Aero 15 X9 Series](https://www.gigabyte.com/Laptop/AERO-15--RTX-20-Series) do not support this.
- Models older than the [Aero 15 KB Series](https://www.gigabyte.com/Laptop/AERO-15--Intel-10th-Gen) use the same value for all fans.

Aero/AORUS laptops support reading the current PWM for each fan. This should not be confused with the custom fan speed, which returns the PWM for use in custom fan mode.

The sysfs and HWMON nodes are read-only, and stay that way until a firmware mechanism is found that actually sets a proportional duty. **Four were tried on a Gigabyte Gaming A16 and none worked:**

- `0x6A` writes `ADJF`, a **single bit**, and runs the fans flat out.
- `0x70` writes the per-fan targets and *ignored* them, then **stopped both fans** when asked for 100%.
- `0x46`/`0x47` write the duty and the target together, and the fans did not move across 30-70%.
- `0x68` writes an indexed fan curve. The store lands and the controller never acts on it — the read-back field that would have confirmed a point is never populated.

The embedded controller decides what to do with those bytes, and no ACPI method
reads them back as anything but storage, so there is nothing left to analyse —
only experiments. The sysfs node will only return the PWM for the CPU fan, while the HWMON nodes have separate channels for CPU and GPU fans.

**Node:** `/sys/devices/platform/gigabyte_laptop/fan_pwm`

### `fan_pwm` and hwmon `pwm1` are the same reading on different scales

Both read the same firmware method. Neither is wrong, but they do not print the
same number:

| Node | Scale | Example |
|---|---|---|
| `fan_pwm` | the controller's own duty, **unconverted** | `31` |
| hwmon `pwm1` | the hwmon convention, **0-255** | `79` |

`31 * 255 / 100 = 79`. The controller works in percent, and hwmon defines
`pwmX` as 0-255, so the driver converts for hwmon and leaves its own node
alone. Read `fan_pwm` for the controller's figure, `pwm1` for something a
standard hwmon tool will interpret correctly. See `HWMON.md`.

## Performance mode (Gigabyte Gaming models)

**Disclaimer:** The next three nodes only exist on Gigabyte Gaming (2025+)
models, as they use method IDs that older Aero/AORUS firmware does not have.
They are hidden on every other model.

Gigabyte Gaming laptops can set the discrete GPU's TGP/CTGP budget through the
NPCF interface. Three modes are available:

- Eco (0)
- Balanced (1)
- Boost (2)

The firmware cannot report which mode is active: method `0xED` exists for
writing but has no matching read, so this node returns the last value written to
it rather than the mode actually in effect. It starts at `0` when the driver
loads, whatever the firmware is doing. The firmware also resets the mode on
every boot.

**On a Gigabyte Gaming A16 (`GA65TH`, BIOS FB03) this works on mains and not
on battery.** Measured 29 Oct 2026 on AC, reading
`nvidia-smi --query-gpu=enforced.power.limit`:

| `perf_mode` | GPU power limit |
|---|---|
| `0` eco | **50 W** (the VBIOS default) |
| `1` balanced | **60 W** |
| `2` boost | **70 W** |

A power limit is a setting, not a measurement, so it moves at idle — the sweep
needs no load. Allow a few seconds after each write before reading back; the
limit does not update instantly.

**Read the limit as a minimum over a window, not as a single sample.**
`enforced.power.limit` is the limit Dynamic Boost is *currently* arbitrating,
not the tier that was selected, and it moves on its own. Measured on this
machine with nothing being written: 60 W for fifteen seconds, then 75 W for
twenty, then back to 60 W. Sampling once lands wherever arbitration happened to
be at that instant.

The tier is the **floor**, because arbitration only ever raises the limit above
the selected base. So sample for 25 seconds or more and take the smallest value:

```sh
for i in $(seq 25); do
	nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader
	sleep 1
done | sort -n | head -1
```

This matters most on a machine where `amd_pmf` is loaded, which adds a second
power manager and is what woke the arbitration up here. Readings taken before
that were repeatable to the watt. `tests/test-gpu-power.sh` does this sampling
itself.

**On battery it does nothing**, and that half is genuinely blocked below this
driver. `nvidia-powerd` reports `DC power limits table is not supported` and
`Client (presumably SBIOS) has requested to disable Dynamic Boost DC
controller` — the firmware withholds the battery power-limit table, so there
is nothing for the daemon to apply. Check with
`journalctl -u nvidia-powerd -b | head`. `nvidia-smi -pl` is refused in both
cases, because the platform owns the power limit on laptop GPUs; that is
normal and is why this node exists.

**The same method also programs the APU's own power limits**, through a
separate controller channel that does not involve the graphics card or
`nvidia-powerd` at all. Each mode writes **three** limits — one sustained and
two short-burst — and on mains they are:

| `perf_mode` | sustained | short-burst | fast-burst |
|---|---|---|---|
| `0` eco | 45 W | **65 W** | 65 W |
| `1` balanced | 65 W | **65 W** | 80 W |
| `2` boost | 70 W | **80 W** | 80 W |

**That half was measured on 29 Oct 2026 and it works too.** Under a heavy
all-core load on mains, package power stepped with the mode, and the plateau
matched the **short-burst** column every time:

| `perf_mode` | measured package power |
|---|---|
| `0` eco | **~65 W** |
| `1` balanced | **~65 W** |
| `2` boost | **~80 W** |

**It is the short-burst limit that binds**, and mode 1 is what shows it: that
is the only mode where the short-burst and fast-burst figures differ (65 W
against 80 W), and the part plateaued at 65 W. Had the fast-burst limit been
the ceiling, mode 1 could have reached 80 W. Whether the fast-burst figure is
enforced at all is therefore **unproven** — the other two modes have both
columns equal and cannot tell them apart.

**The sustained limit is not enforced**, and that was checked properly rather
than inferred. Mode 0 was held under load for **five minutes**, sampled every
second: all 300 samples sat at 64–65 W against its programmed 45 W, with no
step down and the temperature stable at 86–89 °C. Five minutes is well past any
plausible sustained window, so the 45 W figure is written and ignored.

In short, of the three limits each mode programs, **only the short-burst one
has any observable effect.** The sustained figure does nothing, and the
fast-burst figure cannot be told apart from the short-burst one on two of the
three modes.

**A light load will show none of this.** An earlier attempt used a simple
integer load that drew about 62 W — three watts under the 65 W ceiling — so no
mode was ever at its limit and the readings looked flat. A power limit cannot
be observed by a load that never reaches it. Use something that genuinely
saturates the vector units.

**Mode 2 runs hot.** The same test measured 97 °C with the fans pinned to the
gaming preset. That is within spec for this part, but it is the real cost of
the top tier under a heavy sustained load.

So, each part held to what was measured: **on mains, `perf_mode` controls both
the GPU power limit and the APU package limit**, through two independent
firmware channels. On battery the GPU half does nothing, for reasons outside
this driver. The APU half has not been measured on battery — the firmware
writes a different and lower set of limits there, so nothing above says what
happens.

Do not read the battery case as the write failing — the write lands and the
firmware executes it; what differs is whether anything downstream acts on it.

**Node:** `/sys/devices/platform/gigabyte_laptop/perf_mode`

## GPU power preset (Gigabyte Gaming models)

The power profile your desktop selects sets the GPU tier as well as fan policy.
This node decides whether it is allowed to:

| Value | Meaning |
|---|---|
| `auto` | follow the power profile |
| `eco` | pinned to `perf_mode 0` (50 W) |
| `balanced` | pinned to `perf_mode 1` (60 W) |
| `boost` | pinned to `perf_mode 2` (70 W) |

**Node:** `/sys/devices/platform/gigabyte_laptop/power_preset`

The mapping a profile applies while this reads `auto`:

| Profile | fans | GPU |
|---|---|---|
| `low-power` / `quiet` | silent | 50 W |
| `balanced` | silent | 60 W |
| `performance` | normal | 70 W |

**Anything but `auto` outranks the profile.** Pin `boost` and your choice
survives the desktop switching to balanced when you unplug. Setting it back to
`auto` re-applies the current profile immediately. Writing `perf_mode` directly
moves this node to match, so it can never report a tier that is not in effect.

These are the same rules `fan_preset` follows, so fans and GPU power behave
identically — and they are independent: pinning the fans does not freeze GPU
power, or the other way round.

```sh
S=/sys/devices/platform/gigabyte_laptop
cat $S/power_preset                          # auto
echo boost | sudo tee $S/power_preset        # pin the top tier
nvidia-smi --query-gpu=enforced.power.limit --format=csv,noheader
# allow a few seconds -- the limit does not update instantly
echo auto  | sudo tee $S/power_preset        # back to following the profile
```

**On battery this does nothing to GPU power.** Fan policy still changes with
the profile, but the GPU half is blocked below this driver: the firmware
withholds the battery power-limit table from `nvidia-powerd` and disables its
battery Dynamic Boost controller, so there is no consumer to apply the change.
See Performance mode above. Nothing in this driver can change that.

**It starts at `auto` every time the driver loads**, and that is deliberate
rather than a limitation. The firmware has no command to read the current
performance mode back, so a remembered pin would be a claim about hardware
state nobody had verified. Reverting to `auto` and taking the profile's tier
reports what is actually in effect. In practice the desktop applies a profile
within a fraction of a second of boot, so the tier is set and accurate almost
immediately.

`gpu_boost` is a separate axis and is left alone by profiles. It zeroes or
restores the boost headroom on top of whichever tier is selected — see GPU
boost above.

**Example:** To switch to boost mode:

```sh
echo '2' | sudo tee /sys/devices/platform/gigabyte_laptop/perf_mode
```

## Dynamic boost (Gigabyte Gaming models)

Gigabyte Gaming laptops support dynamic boost, which shifts power between the
CPU and the discrete GPU under load. The embedded controller takes this value
inverted, and the driver hides that, so the node reads back whatever was
written to it: `0 -> 1 -> 0` round-trips correctly.

**Which value means "enabled" is unverified.** It is `0` to disable and `1` to
enable on the model this was ported from, but confirming it needs the GPU's
power limit to respond, and on `GA65TH` that path is broken (see Performance
mode above). The node is self-consistent either way; it may be semantically
inverted.

**Node:** `/sys/devices/platform/gigabyte_laptop/dynamic_boost`

## Turbo fan (Gigabyte Gaming models)

Gigabyte Gaming laptops can run their fans at full speed. Writing the embedded
controller's turbo fan bit on its own does not hold the fans there, so this node
engages turbo the way the firmware does: it programs the highest safe custom fan
duty (229), then enables fixed fan mode.

The fan mode and custom fan speed in use beforehand are restored when turbo is
switched off, so this node can be toggled without losing a custom fan curve.

**Node:** `/sys/devices/platform/gigabyte_laptop/fan_turbo`

**Example:** To run the fans at full speed:

```sh
echo '1' | sudo tee /sys/devices/platform/gigabyte_laptop/fan_turbo
```

## Debug method

**Disclaimer:** This node evaluates an arbitrary WMI read method. It is a
development aid, not a supported interface.

**Root only, for reading as well as writing** (mode `0600`). Reading it is not
passive — it evaluates a firmware method — so it is not something an
unprivileged process should be able to trigger.

The node takes a method ID and an optional argument, then reads that method and
prints the result:

```sh
echo '0xE7' | sudo tee /sys/devices/platform/gigabyte_laptop/debug_method
sudo cat /sys/devices/platform/gigabyte_laptop/debug_method
# method 0xe7 arg 0x0 -> 0x0 (0) [implemented]
```

The argument matters when checking whether a method exists at all. The firmware
answers an unimplemented method ID with whatever argument was passed in, so a
read with argument 0 returns 0 either way. Reading with a distinctive argument
tells the two apart, and the node says so when the result matches:

```sh
echo '0xED 0x5A' | sudo tee /sys/devices/platform/gigabyte_laptop/debug_method
sudo cat /sys/devices/platform/gigabyte_laptop/debug_method
# method 0xed arg 0x5a -> 0x5a (90) [reply was not an integer: absent, or a method that returns a buffer] [argument echoed back -- absent]
```

The bracketed marker is the conclusive half: a reply that is not an integer is
the firmware's `Default { Return (Arg2) }` catch-all, which means no case for
that ID. The echo note is corroboration, since a sentinel can collide with a
real value. **If you parse this node, match `[implemented]` with its
brackets** — the negative string contains the word as a substring, so a bare
`grep implemented` passes both cases.

**Node:** `/sys/devices/platform/gigabyte_laptop/debug_method`

## Debug method (write)

**Disclaimer:** This node performs an arbitrary WMI **write**. It is a
development aid, not a supported interface, and it can leave the machine in a
state the driver does not know about.

Root only (mode `0600`). The write happens when you write the node, not when
you read it; reading reports what the last one did.

```sh
echo '0x7D 1' | sudo tee /sys/devices/platform/gigabyte_laptop/debug_method_write
sudo cat /sys/devices/platform/gigabyte_laptop/debug_method_write
# method 0x7d arg 0x1 -> wrote, replied with a buffer (void case, or no case for this ID -- check the field)
```

Method `0x7D` is one of the cases that assigns its field and falls through
without a `Return`, which is why it answers that way rather than with a value.
A method that does return one reads back as:

```text
method 0x46 arg 0x32 -> wrote, replied 0x32 (50)
```

and one whose reply carries nothing at all reads back as:

```text
method 0xfa arg 0x0 -> wrote, no reply (void case)
```

A third of this firmware's `WMBD` cases assign their embedded-controller field
and fall through with no `Return`, and `WMBD` also ends in
`Default { Return (Arg2) }` with the argument passed as a buffer — so a buffer
back means *either* a method that worked and returned nothing useful, *or* one
the firmware has no case for. **Check the field** with the read node to tell
them apart. A failed write means the ACPI evaluation itself failed, which is the
only reliable signal here.

**Hazards, all real:**

- **A wrong fan duty can stop the fans rather than slow them.** Method `0x70`
  with a target of 100% stops both fans on a Gigabyte Gaming A16. Sweep upward
  from a low value, watch `fan1_input` after each step, and stop at the first
  reading that does not rise.
- **Poking the fan methods desynchronises the driver.** `fan_mode` still reports
  what the driver last set, not what you just wrote. Rewrite `fan_mode` or
  `fan_preset` afterwards to put the two back in step.
- **Method `0x63` is refused.** It wants a five-byte argument and this setter
  passes four, so the firmware would fail on the fifth byte *after* writing four
  bytes of CMOS NVRAM, leaving a half-written block that the firmware reads at
  the next boot.

**Node:** `/sys/devices/platform/gigabyte_laptop/debug_method_write`

## Power profiles

The driver registers a `platform_profile` handler, so the desktop's power
profile selector drives the fan policy:

| Profile | Fan mode |
|---|---|
| `low-power` | silent |
| `quiet` | silent |
| `balanced` | silent |
| `performance` | normal |

The mapping is one notch quieter than the obvious one, because the embedded
controller's normal and gaming curves both ramp the fans hard. Power saver and
balanced therefore share the silent preset, and performance gets normal.

**Gaming fan mode is deliberately not offered as a profile.** It is the loudest
preset and is reserved as its own axis, to be cycled directly rather than
through a battery profile. Select it with
`echo 2 > /sys/devices/platform/gigabyte_laptop/fan_mode`.

`low-power` and `quiet` both map to silent because the two consumers prefer
different names: `tuned`'s `powersave` profile asks for `low-power|quiet` and
takes whichever is offered first, while its power-profiles-daemon shim only
recognises `low-power`, `balanced` and `performance` when translating back for
the desktop indicator.

**Nodes:**

```text
/sys/firmware/acpi/platform_profile
/sys/class/platform-profile/platform-profile-*/profile
```

The first is the aggregate the ACPI core maintains, and is what `tuned` and
power-profiles-daemon write. It is the stable path; prefer it.

The class directory holds one entry per registered handler, numbered in
registration order, so the index is not fixed — `amd_pmf` registers a second
one named `amd-pmf` on machines where it binds. Find this driver's by name
rather than assuming index 0:

```sh
grep -l '^gigabyte_laptop$' /sys/class/platform-profile/*/name
```

When more than one handler is registered, the aggregate is the intersection of
their choices and reads `custom` when they disagree.

**Example:** To switch to the performance fan policy:

```sh
echo 'performance' | sudo tee /sys/firmware/acpi/platform_profile
```

A profile switch deliberately does **nothing to the fans** in two cases:

- the fan preset is not `auto`, so the Mode key or a direct write has pinned a
  preset, and
- the fans are not under embedded-controller control — the fan mode is the
  custom curve, a held duty, or full speed.

Both are deliberate choices, and a profile arriving from the desktop should not
override them. The profile is still remembered and takes effect the next time it
is set, once the preset is back on `auto` and the fans are back under controller
control.

**On Gigabyte Gaming models a profile also sets the GPU power tier**, while
`power_preset` reads `auto`:

| Profile | Fan mode | GPU power |
|---|---|---|
| `low-power` / `quiet` | silent | 50 W |
| `balanced` | silent | 60 W |
| `performance` | normal | 70 W |

Measured on a GAMING A16 5TH. The two are independent axes with the same
pinning rules, so holding one does not freeze the other — see "GPU power
preset" above. On battery the fan half still applies and the GPU half does
nothing, for reasons outside this driver.
