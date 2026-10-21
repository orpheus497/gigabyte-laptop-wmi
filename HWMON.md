# HWMON.md

This document outlines the HWMON nodes exposed by this driver. The nodes can be found in `/sys/devices/platform/gigabyte_laptop/hwmon/hwmonX`.

## Fans

All `fanX_input` nodes are read-only, and all values returned are in revolutions per minute (RPM). Channel 1 is for CPU, channel 2 is for GPU, channel 3 is for fan 3 (if equipped), and channel 4 is for fan 4 (if equipped).

## PWM

**Disclaimers:**

- Models older than the [Aero 15 X9 Series](https://www.gigabyte.com/Laptop/AERO-15--RTX-20-Series) do not support this.
- Models older than the [Aero 15 KB Series](https://www.gigabyte.com/Laptop/AERO-15--Intel-10th-Gen) use the same value for all fans.

`pwmX` and `pwmX_enable` are **read-only**. Channel 1 is for CPU and channel 2 is for GPU. Fans 3 and 4 (if equipped) do not have a way of measuring their PWM whatsoever.

`pwmX` reports the controller's live duty, scaled. The embedded controller works in percent — `FDTY` and `GDTY` are eight-bit fields the firmware treats as 0–100 — while hwmon defines these attributes as 0–255, so the driver converts. An EC duty of 22% reads as `56`.

`pwmX_enable` reports `2` (automatic) whenever the controller is driving the fans from temperature, `1` if a duty is being held, and `0` for the fan mode that runs them flat out.

### Why writing is not supported

Two firmware methods were tried on a GAMING A16 5TH and neither gives proportional control:

- **`FAN_FIXED_MODE` (`0x6A`)** writes `ADJF`, which is a **single bit**. It cannot express a duty, and latching it runs the fans at maximum regardless of what duty was programmed. This is the mechanism `fan_turbo` uses.
- **`FAN_AUTO_MODE` (`0x70`)** writes `FAN1` and `FAN2`, the per-fan targets, and looked like the answer. In practice the controller ignored targets of 25%, 50% and 75%, continuing to run its own curve — and a target of 100% **stopped both fans**.

Because a wrong duty can stop the fans rather than merely run them at the wrong speed, the attributes stay read-only until a mechanism is confirmed on hardware. Untried leads are recorded in `CLAUDE.md`.

## Temperature

All `tempX_input` nodes are read-only, and all values are in Celsius * 1000 (so `sensors` can read it correctly). Channel 1 is for CPU, channel 2 is for GPU, and channel 3 is for the motherboard.
