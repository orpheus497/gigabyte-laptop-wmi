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

Four firmware methods were tried on a GAMING A16 5TH and none gives proportional control. The two that come closest:

- **`FAN_FIXED_MODE` (`0x6A`)** writes `ADJF`, which is a **single bit**. It cannot express a duty, and latching it runs the fans at maximum regardless of what duty was programmed. This is the mechanism `fan_turbo` uses.
- **`FAN_AUTO_MODE` (`0x70`)** writes `FAN1` and `FAN2`, the per-fan targets, and looked like the answer. In practice the controller ignored targets of 25%, 50% and 75%, continuing to run its own curve — and a target of 100% **stopped both fans**.

The other two were `0x46`/`0x47`, which write a field the controller uses as its *output* rather than an input, and `0x68`, an indexed fan curve whose store lands in controller memory and is never acted on.

Because a wrong duty can stop the fans rather than merely run them at the wrong speed, the attributes stay read-only. All four mechanisms and the reasoning behind each rejection are recorded in `CLAUDE.md`.

## Temperature

All `tempX_input` nodes are read-only, and all values are in Celsius * 1000 (so `sensors` can read it correctly). Channel 1 is for CPU, channel 2 is for GPU, and channel 3 is for the motherboard.

### Channel 1 is a slow average, not an instantaneous reading

Measured on a GAMING A16 5TH: during a 120-second all-core load, channel 1 held
**66 °C for every one of 120 samples** while the CPU's own sensor ran
78 → 86 → 65 °C. Sampled at idle afterwards it changed **once in 60 seconds**.
It also reads high at idle and low under load, which is the signature of a
long-window average rather than a fault.

**Do not use this channel for anything responsive** — a fan curve, an on-screen
display, a thermal alert. It will be minutes stale and will under-read badly
under load. For an instantaneous CPU temperature use the CPU's own driver
(`k10temp` on AMD, `coretemp` on Intel).

This is the controller's published value, not a driver defect, and the
controller's own fan logic does not use it: in the same run the fans tracked the
load correctly while this number sat still. So a stale reading here is a
reporting limitation, not a cooling one.

Channel 2 has no such problem — it matched the GPU's own sensor exactly in the
same test.
