# HWMON.md

This document outlines the HWMON nodes exposed by this driver. The nodes can be found in `/sys/devices/platform/gigabyte_laptop/hwmon/hwmonX`.

## Fans

All `fanX_input` nodes are read-only, and all values returned are in revolutions per minute (RPM). Channel 1 is for CPU, channel 2 is for GPU, channel 3 is for fan 3 (if equipped), and channel 4 is for fan 4 (if equipped).

## PWM

`pwmX` and `pwmX_enable` are read/write. Channel 1 is for CPU and channel 2 is for GPU. Fans 3 and 4 (if equipped) do not have a way of measuring their PWM whatsoever.

`pwmX_enable` follows the hwmon interface:

- `1` — manual. Userspace sets the duty through `pwmX`. The driver latches fixed fan mode to make the duty take effect.
- `2` — automatic. The embedded controller drives the fans from temperature, which is the normal, silent, gaming, custom-curve and auto-maximum fan modes.
- `0` — full speed. Programs the highest safe duty and latches fixed mode, the same mechanism `fan_turbo` uses.

Writing `pwmX` implies `pwmX_enable = 1`, since a duty has no effect until fixed mode is latched. Write `2` to hand the fans back to the controller.

Duties above 229 have been reported to stop the fans entirely on some models, so a write above that is **clamped** rather than rejected: running slightly slower than asked is a better failure than a stopped fan under load.

## Temperature

All `tempX_input` nodes are read-only, and all values are in Celsius * 1000 (so `sensors` can read it correctly). Channel 1 is for CPU, channel 2 is for GPU, and channel 3 is for the motherboard.
