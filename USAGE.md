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
remembered but does not touch the fans. Selecting `auto` again hands the
decision back to the profile and applies it immediately.

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

## Charging limit

Aero/AORUS laptops support a charging limit. Charging mode must be set to custom for it to take effect. It will only accept numbers between 60 and 100.

**Node:** `/sys/devices/platform/gigabyte_laptop/charge_limit`

**Example:** To set the charging limit to 80 percent:

```text
echo '80' | sudo tee /sys/devices/platform/gigabyte_laptop/charge_limit
```

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

The sysfs and HWMON nodes are read-only, and stay that way until a firmware mechanism is found that actually sets a proportional duty. Two were tried on a Gigabyte Gaming A16 and neither worked: method `0x6A` writes a single bit and runs the fans flat out, and method `0x70` ignored the target entirely and *stopped both fans* when asked for 100%. The sysfs node will only return the PWM for the CPU fan, while the HWMON nodes have separate channels for CPU and GPU fans.

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
# method 0xe7 arg 0x0 -> 0x0 (0)
```

The argument matters when checking whether a method exists at all. The firmware
answers an unimplemented method ID with whatever argument was passed in, so a
read with argument 0 returns 0 either way. Reading with a distinctive argument
tells the two apart, and the node says so when the result matches:

```sh
echo '0xED 0x5A' | sudo tee /sys/devices/platform/gigabyte_laptop/debug_method
sudo cat /sys/devices/platform/gigabyte_laptop/debug_method
# method 0xed arg 0x5a -> 0x5a (90) [echoed argument: method not implemented]
```

**Node:** `/sys/devices/platform/gigabyte_laptop/debug_method`

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
