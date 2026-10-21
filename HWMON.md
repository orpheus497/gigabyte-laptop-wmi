# HWMON.md

This document outlines the HWMON nodes exposed by this driver. The nodes can be found in `/sys/devices/platform/gigabyte_laptop/hwmon/hwmonX`.

## Fans

All `fanX_input` nodes are read-only, and all values returned are in revolutions per minute (RPM). Channel 1 is for CPU, channel 2 is for GPU, channel 3 is for fan 3 (if equipped), and channel 4 is for fan 4 (if equipped).

## PWM

`pwmX` and `pwmX_enable` are read/write. Channel 1 is for CPU and channel 2 is for GPU. Fans 3 and 4 (if equipped) do not have a way of measuring their PWM whatsoever.

`pwmX_enable` follows the hwmon interface:

- `1` — manual. Userspace sets the duty through `pwmX`, and both fans are held at it.
- `2` — automatic. The embedded controller drives the fans from temperature: the normal, silent, gaming and custom-curve fan modes.
- `0` — full speed, with no speed control. This is the fan mode `fan_turbo` uses.

Writing `pwmX` implies `pwmX_enable = 1`, since a duty only applies once the controller has been told to hold it. Write `2` to hand the fans back.

**`pwmX` is scaled.** hwmon defines these attributes as 0–255, but this embedded controller works in percent, so the driver converts in both directions. A write of `128` becomes 50% and reads back as `128`. Passing 0–255 through unscaled would ask the controller for up to 255%, which it simply pins to full speed — every duty above about 100 would mean "maximum".

Fan speed control is only proportional through `pwmX_enable = 1`. The fan mode the driver calls *fixed* sets a single-bit flag in the controller rather than a duty, so it can only mean full speed, which is why it backs `pwmX_enable = 0`.

## Temperature

All `tempX_input` nodes are read-only, and all values are in Celsius * 1000 (so `sensors` can read it correctly). Channel 1 is for CPU, channel 2 is for GPU, and channel 3 is for the motherboard.
