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

**It is not established that it restarts the watcher after a module reload.**
An earlier version of this file claimed it does. The journal does not support
that: across six boots every single start of the service sits immediately after
a boot marker, and none coincides with the mid-session `rmmod`/`modprobe` that
`scripts/install-dkms.sh` performs. `PathExists=` relies on inotify, and
inotify on `/sys` is not contractually reliable, so this is the expected
failure rather than a surprise.

If the watcher stops reacting to the Mode key after a driver reinstall, restart
it by hand. **`restart`, not `start`** — if the watcher survived the reload with
a stale descriptor the unit is still active, and `start` would be a no-op while
notifications stayed broken; `restart` also starts a stopped unit, so it is
correct either way, which matters because which of the two happens is exactly
what has not been measured:

```sh
systemctl --user restart gigabyte-fan-preset-notify.service
```

A udev rule would make it automatic, and is the documented remedy if this turns
out to matter:

```udev
SUBSYSTEM=="platform", KERNEL=="gigabyte_laptop", TAG+="systemd", \
  ENV{SYSTEMD_USER_WANTS}+="gigabyte-fan-preset-notify.service"
```

It is deliberately **not** shipped yet: `SYSTEMD_USER_WANTS` does not replay for
a device that is already present, so the `.path` unit is still needed for the
login case, and whether the watcher actually dies on a reload — rather than
surviving with a stale descriptor — has not been measured. Measure before adding
a second activation path.

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

## GPU boost (added in version 0.1.0)

**Disclaimer:** Models older than the [Aero 15 X9 Series](https://www.gigabyte.com/Laptop/AERO-15--RTX-20-Series) do not support this, as it requires NVIDIA's Dynamic Boost from their Max-Q technologies.

Aero/AORUS laptops support boosting the discrete GPU's power limit. Even though this is controlled by `nvidia-powerd`, the embedded controller can control this as well.

Laptops with RTX 3000 series GPUs or newer have three different modes, while older models have one.

**Node:** `/sys/devices/platform/gigabyte_laptop/gpu_boost`

**Example:** To enable GPU boost:

```sh
echo '1' | sudo tee /sys/devices/platform/gigabyte_laptop/gpu_boost
```

## USB toggles (added in version 0.1.0)

Aero/AORUS laptops support USB power output when they are asleep (S3) or in hibernation (S4). Newer models have dropped the latter, and will return 0 by default. These toggles are currently read-only.

**Nodes:**

```text
/sys/devices/platform/gigabyte_laptop/usb_charge_s3_toggle
/sys/devices/platform/gigabyte_laptop/usb_charge_s4_toggle
```

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

## PWM (added in version 0.2.0)

**Disclaimers:**

- Models older than the [Aero 15 X9 Series](https://www.gigabyte.com/Laptop/AERO-15--RTX-20-Series) do not support this.
- Models older than the [Aero 15 KB Series](https://www.gigabyte.com/Laptop/AERO-15--Intel-10th-Gen) use the same value for all fans.

Aero/AORUS laptops support reading the current PWM for each fan. This should not be confused with the custom fan speed, which returns the PWM for use in custom fan mode.

The sysfs and HWMON nodes are read-only, and stay that way until a firmware mechanism is found that actually sets a proportional duty. Three were tried on a Gigabyte Gaming A16 and none worked:

- `0x6A` writes `ADJF`, a **single bit**, and runs the fans flat out.
- `0x70` writes the per-fan targets and *ignored* them, then **stopped both fans** when asked for 100%.
- `0x46`/`0x47` write the duty and the target together, and the fans did not move across 30-70%.

The embedded controller decides what to do with those bytes, and no ACPI method
reads them back as anything but storage, so there is nothing left to analyse —
only experiments. The sysfs node will only return the PWM for the CPU fan, while the HWMON nodes have separate channels for CPU and GPU fans.

**Node:** `/sys/devices/platform/gigabyte_laptop/fan_pwm`

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

**On a Gigabyte Gaming A16 (`GA65TH`, BIOS FB03) the write lands but nothing
applies it.** The WMI call succeeds and the firmware sets its NPCF values, but
the GPU's power limit does not move: `nvidia-powerd` cannot initialise, because
the SBIOS does not hand over the power-limit table it needs
(`Failed to get SysPwrLimitGetInfo`). The limit stays capped below the VBIOS
default and `nvidia-smi -pl` is refused as well, since the platform owns TGP on
laptop GPUs. Nothing in this driver can change that; check whether a BIOS or
driver update has fixed it with `journalctl -u nvidia-powerd -b | head`.

**Node:** `/sys/devices/platform/gigabyte_laptop/perf_mode`

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
# method 0xed arg 0x5a -> 0x5a (90) [not implemented: reply was not an integer] [argument echoed back]
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

On Gigabyte Gaming models this selects fan policy only. It does not change the
discrete GPU's power budget: that is governed by the NVIDIA platform controller
interface rather than by the embedded controller.
