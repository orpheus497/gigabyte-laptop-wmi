// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *  gigabyte-laptop.c - Gigabyte laptop WMI driver
 *
 *  Copyright (C) 2023 Albert Tang
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <acpi/battery.h>
#include <linux/acpi.h>
#include <linux/cleanup.h>
#include <linux/dmi.h>
#include <linux/hwmon.h>
#include <linux/hwmon-sysfs.h>
#include <linux/init.h>
#include <linux/input.h>
#include <linux/input/sparse-keymap.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/leds.h>
#include <linux/platform_device.h>
#include <linux/platform_profile.h>
#include <linux/power_supply.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/wmi.h>
#include <linux/string.h>

#define GIGABYTE_LAPTOP_VERSION "0.2.0"
#define GIGABYTE_LAPTOP_FILE  KBUILD_MODNAME

MODULE_AUTHOR("Albert Tang");
MODULE_DESCRIPTION("Gigabyte laptop WMI driver");
MODULE_LICENSE("GPL");
MODULE_VERSION(GIGABYTE_LAPTOP_VERSION);

/* _SB_.PCI0.AMW0._WDG */
#define WMI_EVENT "ABBC0F72-8EA1-11D1-00A0-C90629100000" // Hopefully, it's used for hotkeys
#define WMI_METHOD_WMBC "ABBC0F6F-8EA1-11D1-00A0-C90629100000" // Seems to only return values
#define WMI_METHOD_WMBD "ABBC0F75-8EA1-11D1-00A0-C90629100000" // Will probably do most of the work.

/* WMI method arguments */
// Not supported by Aero 14 W
#define GPU_QBOOST       0x51
#define FAN_SILENT_MODE  0x57
// Mislabelled: on Gaming (2025+) firmware 0x63 is the five extended-CMOS bytes
// RXCM(0xD2)..RXCM(0xD6), not a timestamp. Read-only here for that reason.
#define POWER_ON_TIME    0x63
#define CHARGING_MODE    0x64
#define CHARGING_LIMIT   0x65
// Supported by Aero 14 W
#define FAN_PWM          0x50
#define FAN_CUSTOM_MODE  0x67
#define FAN_INDEX_VALUE  0x68
#define FAN_FIXED_MODE   0x6A
#define FAN_CUSTOM_SPEED 0x6B
#define BATT_CYCLE2      0x6D
#define BATT_CYCLE       0x6E
#define FAN_AUTO_MODE    0x70
#define FAN_GAMING_MODE  0x71
#define USB_SLEEP        0x7A
#define USB_HIBERNATE    0x7B
#define WIFI_TOGGLE      0xC2
#define TOUCHPAD_ENABLED 0xCA
#define TEMP_CPU         0xE1
#define TEMP_GPU         0xE2
#define FAN_CPU_RPM      0xE4
#define FAN_GPU_RPM      0xE5
#define FAN_THREE_RPM    0xE8 // 2023 AORUS 17
#define FAN_FOUR_RPM     0xE9 // 2023 AORUS 17X
#define KBD_BRIGHTNESS   0xF6 // KBLL in PECM. Not Gaming-only: gated at runtime
#define LIGHT_SENSOR     0xF7 // WARNING: Behavior changes in VE models
#define FAN_SILENT_OLD   0xFA // Older Aero and P-series models
#define LIGHT_SENSOR_NEW 0xFC // Added in VE models, returns as buffer

// Gigabyte Gaming (2025+) models only (e.g. A16 CWH, A16 5TH)
#define FAN_TURBO        0x7D // EC TFAN bit, max fan speed
#define DYN_BOOST        0xE7 // NPCF dynamic boost (write 0 to enable)
#define PERF_MODE        0xED // NPCF perf mode, controls GPU TGP/CTGP boost

// Adding support (WIP)
#define CPU_FAN_DUTY     0x46 // Aero 15 VB
#define GPU_FAN_DUTY     0x47 // Aero 15 VB

// Fan curves
#define FAN_CURVE_POINTS 15

/*
 * Highest custom fan duty that is safe to program. Duties above this have been
 * reported to stop the fans entirely on some models, so never exceed it when
 * the driver picks a duty by itself.
 */
#define FAN_DUTY_MAX     0xE5

/*
 * Two levels, off and on, measured rather than assumed. The firmware is no help
 * -- KBLL is an 8-bit field with no clamp, mask or comparison anywhere in the
 * DSDT -- but the embedded controller answers the question itself: it publishes
 * its own level as a 0xF6 WMI event, and across repeated Fn+Space presses the
 * state byte only ever alternates 0x00 and 0x01 in step with the backlight
 * going off and on. Writing 0 and 1 reproduces that; Fn+Space still works
 * afterwards.
 *
 * Do not raise this on the grounds that the field could hold more. The EC never
 * reports a level above 1, so a larger max_brightness would offer the desktop
 * positions that mean nothing and cannot be read back.
 */
#define KBD_BRIGHTNESS_MAX 1

struct fan_curve_data {
	u8 temperature[FAN_CURVE_POINTS];
	u8 speed[FAN_CURVE_POINTS];
};

struct gigabyte_laptop_wmi {
	struct platform_device *pdev;
	struct device *hwmon_dev;
	struct device *ppdev;
	struct led_classdev kbd_led;
	struct acpi_battery_hook battery_hook;
	struct power_supply *battery;
	struct fan_curve_data fan_curve;

	/*
	 * The charge ceiling is two fields written in sequence, and the order
	 * matters: enabling BCPS latches whatever BCPC already holds. Three
	 * writers reach them now -- charge_mode, charge_limit and the battery's
	 * charge_control_end_threshold -- so the pair needs serialising the way
	 * the fan state does.
	 */
	struct mutex charge_lock;

	/*
	 * Every fan transition is a read-modify-write: set_fan_mode() decides
	 * what to clear from the mode currently cached here, and the caller
	 * writes the new one back afterwards. Two writers interleaving there
	 * leave the cached mode describing a state the EC is not in, and
	 * sysfs attributes, hwmon and platform_profile are three independent
	 * entry points into it.
	 */
	struct mutex fan_lock;

	/*
	 * GPU power is a second axis with the same shape as the fan one: a
	 * preset ring, a platform_profile mapping, and a raw node, all three
	 * able to move perf_mode. Separate from fan_lock rather than folded
	 * into it because the two axes are independent -- pinning the fans must
	 * not freeze GPU power -- and because profile_set touches both, so one
	 * lock covering both would mean holding a fan lock across a GPU write.
	 */
	struct mutex power_lock;

	enum platform_profile_option profile;

	int fan_mode;
	int fan_custom_speed;
	u8 fan_preset;
	u8 power_preset;
	int charge_mode;
	int charge_limit;
	int gpu_boost;
	int fan_curve_index;
	int perf_mode;
	int dynamic_boost;
	int fan_turbo;

	// Fan state to restore when turbo fan mode is switched off
	int fan_turbo_saved_mode;
	int fan_turbo_saved_speed;

	u32 debug_arg;
	u32 debug_write_arg;
	int debug_write_result;
	int debug_write_ret;
	acpi_object_type debug_write_type;

	u8 gaming_family;
	u8 fan_silent_method;
	u8 debug_method;
	u8 debug_write_method;
	u8 dual_fan_speed_enabled;
	u8 light_sensor_method;
	u8 has_dgpu_ejector;
	u8 has_kbd_backlight;
	u8 has_charge_control;
	u8 has_three_fans;
	u8 has_four_fans;
};

/*
 * pwm_enable values, as Documentation/hwmon/sysfs-interface defines them.
 * The names upstream used had AUTO and MANUAL the other way round, which did
 * not match what userspace expects of the attribute.
 */
enum fan_ctrl {
	GIGABYTE_FAN_CTRL_FULL_SPEED = 0,
	GIGABYTE_FAN_CTRL_MANUAL = 1,
	GIGABYTE_FAN_CTRL_AUTO = 2
};

static struct platform_device *platform_device;

static u8 fan_modes[] = {
	0,
	FAN_SILENT_MODE,
	FAN_GAMING_MODE,
	FAN_CUSTOM_MODE,
	FAN_AUTO_MODE,
	FAN_FIXED_MODE
};

/*
 * Fan preset: what gets to decide fan policy.
 *
 * AUTO hands the decision back to the platform profile, which is the tethered
 * arrangement the desktop's power profile selector drives. The other three pin
 * one of the EC's own presets, gaming included -- and gaming is reachable only
 * this way, because no power profile maps to it on purpose: it is the loudest
 * and does not belong on a battery profile.
 *
 * The Mode key cycles this ring, so the key owns fan policy and the profile
 * owns it only while the ring sits on AUTO. Starts on AUTO, which is zero and
 * so comes free from the kzalloc.
 */
enum fan_preset {
	FAN_PRESET_AUTO = 0,
	FAN_PRESET_SILENT,
	FAN_PRESET_NORMAL,
	FAN_PRESET_GAMING,
	FAN_PRESET_COUNT
};

static const char * const fan_preset_names[] = {
	"auto", "silent", "normal", "gaming"
};

static_assert(ARRAY_SIZE(fan_preset_names) == FAN_PRESET_COUNT);

// Indexed by enum fan_preset. AUTO has no fan mode of its own.
static const int fan_preset_modes[] = { -1, 1, 0, 2 };

// The reverse, for fan modes 0-2. Above that are the custom modes, which no
// preset names.
static const u8 fan_mode_presets[] = {
	FAN_PRESET_NORMAL, FAN_PRESET_SILENT, FAN_PRESET_GAMING
};

/*
 * GPU power preset, the same ring as the fan one and for the same reason: the
 * platform profile owns GPU power only while this sits on AUTO, so a
 * deliberate choice survives tuned switching profile on an AC transition.
 *
 * The tiers are the three the firmware implements, measured on a GAMING A16
 * 5TH against enforced.power.limit: perf_mode 0/1/2 give 50/60/70 W, which is
 * 50 W plus NPCF.ACBT/8. There is no continuous control -- every power value
 * in the firmware is a hardcoded constant -- so these are selectors, not
 * numbers, and the names say tier rather than wattage. A fourth firmware mode
 * exists and is a duplicate of the third on the GPU side, so it is not offered.
 *
 * Starts on AUTO, which is zero and so comes free from the kzalloc. Nothing
 * restores a pinned choice across a reload, because perf_mode has no WMBC read
 * and the firmware cannot be asked what tier it is in. That is the right
 * behaviour rather than a gap: reverting to AUTO and taking the profile's tier
 * reports what is actually in effect, where remembering a pre-reboot pin would
 * claim a state nobody has set.
 */
enum power_preset {
	POWER_PRESET_AUTO = 0,
	POWER_PRESET_ECO,
	POWER_PRESET_BALANCED,
	POWER_PRESET_BOOST,
	POWER_PRESET_COUNT
};

static const char * const power_preset_names[] = {
	"auto", "eco", "balanced", "boost"
};

static_assert(ARRAY_SIZE(power_preset_names) == POWER_PRESET_COUNT);

// Indexed by enum power_preset. AUTO has no tier of its own.
static const int power_preset_modes[] = { -1, 0, 1, 2 };

// The reverse, for perf_mode 0-2.
static const u8 perf_mode_presets[] = {
	POWER_PRESET_ECO, POWER_PRESET_BALANCED, POWER_PRESET_BOOST
};

/*
 * Gigabyte Gaming (2025+) firmware exposes performance mode, dynamic boost and
 * turbo fan through method IDs that older Aero/AORUS firmware does not have.
 */
static bool gigabyte_laptop_family_is(const char *name)
{
	const char *family = dmi_get_system_info(DMI_PRODUCT_FAMILY);

	// Firmware is not obliged to publish a family, so never hand NULL to strcmp
	return family && !strcmp(family, name);
}

static bool gigabyte_laptop_is_gaming_family(void)
{
	return gigabyte_laptop_family_is("GIGABYTE GAMING");
}

/* WMI methods ********************************************/

/*
 * WMBC method (checks value in EC).
 *
 * reply_type, when non-NULL, hands the raw ACPI type back. That is how a caller
 * tells an implemented method from one the firmware has no case for: WMBC ends
 * in Default { Return (Arg2) } and Arg2 arrives as a four-byte buffer, so an
 * unimplemented ID answers with a BUFFER while every implemented field read
 * answers with an INTEGER. That is conclusive in one call where a sentinel
 * value is not, because a sentinel can collide with a real value -- KBLL is
 * eight bits, so 0x5A is a plausible brightness.
 */
static int gigabyte_laptop_get_devstate_typed(u32 method_id, u32 arg2, void *result,
					size_t size, acpi_object_type *reply_type)
{
	union acpi_object *obj;
	acpi_status status;
	struct acpi_buffer buffer = { ACPI_ALLOCATE_BUFFER, NULL };
	struct acpi_buffer input = { sizeof(arg2), &arg2 };

	status = wmi_evaluate_method(WMI_METHOD_WMBC, 0, method_id, &input, &buffer);
	if (ACPI_FAILURE(status))
		return -EIO;

	obj = buffer.pointer;

	if (reply_type)
		*reply_type = obj ? obj->type : ACPI_TYPE_ANY;

	if (obj && obj->type == ACPI_TYPE_INTEGER) {
		// Refuse to truncate an integer into a smaller caller buffer
		if (size < sizeof(int)) {
			kfree(obj);
			return -EINVAL;
		}
		*(int *)result = obj->integer.value;
	}
	else if (obj && obj->type == ACPI_TYPE_BUFFER) {
		if (obj->buffer.length == 0) {
			kfree(obj);
			return -ENODATA;
		}
		/*
		 * The firmware decides how much it hands back, so clamp the copy
		 * to what the caller has room for. This matters because WMBC ends
		 * in Default { Return (Arg2) }, so a method ID the firmware does
		 * not implement returns the argument buffer rather than failing.
		 */
		memcpy(result, obj->buffer.pointer,
			min_t(size_t, size, obj->buffer.length));
	}
	else {
		kfree(obj);
		return -EINVAL;
	}
	kfree(obj);
	return 0;
}

static int gigabyte_laptop_get_devstate_raw(u32 method_id, u32 arg2, void *result, size_t size)
{
	return gigabyte_laptop_get_devstate_typed(method_id, arg2, result, size, NULL);
}

/*
 * Is this method ID implemented at all? An INTEGER reply means the firmware has
 * a case for it; a BUFFER reply is Default { Return (Arg2) } handing the
 * argument straight back. The argument is irrelevant here because only the
 * reply's type is read, which is why this works where a sentinel value does
 * not: KBLL is eight bits, so any sentinel could collide with a real level.
 */
static bool gigabyte_laptop_method_implemented(u32 method_id)
{
	acpi_object_type type = ACPI_TYPE_ANY;
	int output;

	if (gigabyte_laptop_get_devstate_typed(method_id, 0, &output,
					sizeof(output), &type))
		return false;

	return type == ACPI_TYPE_INTEGER;
}

/* Read a single value. The common case. */
static int gigabyte_laptop_get_devstate2(u32 method_id, u32 arg2, int *result)
{
	return gigabyte_laptop_get_devstate_raw(method_id, arg2, result, sizeof(*result));
}

static int gigabyte_laptop_get_devstate(u32 method_id, int *result)
{
	return gigabyte_laptop_get_devstate2(method_id, 0, result);
}

/* Read a method that answers with a buffer, such as the light sensor. */
static int gigabyte_laptop_get_devstate_buf(u32 method_id, void *result, size_t size)
{
	return gigabyte_laptop_get_devstate_raw(method_id, 0, result, size);
}

/*
 * Which light sensor method does this firmware implement, or 0 for neither?
 *
 * The two need different tests, which is why this cannot be the plain
 * implemented() check the other capability gates use. The new method answers
 * with a four-byte buffer whose first byte is a 0xF7 marker the firmware puts
 * there, and a buffer is also what an *unimplemented* ID answers with, since
 * WMBC ends in Default { Return (Arg2) } -- so only the marker separates them.
 * The old method answers with an integer, where the ordinary type test works.
 *
 * Reads the firmware rather than any cached state because is_visible() calls
 * this too, and that runs during sysfs_create_group(), before probe().
 */
static u8 gigabyte_laptop_light_sensor_method(void)
{
	u8 result[4] = { };

	if (!gigabyte_laptop_get_devstate_buf(LIGHT_SENSOR_NEW, result, sizeof(result)) &&
		result[0] == 0xF7)
		return LIGHT_SENSOR_NEW;

	if (gigabyte_laptop_method_implemented(LIGHT_SENSOR))
		return LIGHT_SENSOR;

	return 0;
}

/*
 * WMBD method (sets value in EC).
 *
 * A third of this firmware's WMBD cases assign their EC field and fall off the
 * end of the Switch with no Return -- 0x51, 0x7D and 0xED among the ones
 * written here. The assignment has already happened by then, so **any** reply
 * that comes back from a successful evaluation means the write landed.
 *
 * Nothing in the reply can prove otherwise, which is why this does not try.
 * WMBD ends in Default { Return (Arg2) } and Arg2 arrives as a 4-byte buffer,
 * so an unimplemented ID answers with that buffer -- but a void case answers
 * with something that is not an integer either, and the two are not reliably
 * distinguishable here. Measured on a GAMING A16 5TH: writing 0x7D came back
 * non-integer and the EC bit changed anyway, so treating a non-integer reply as
 * failure rejected a write that had already happened. The ACPI status is the
 * only trustworthy signal for a setter.
 *
 * reply_type, when non-NULL, hands the raw type to the caller. Only the debug
 * node wants it, to show a human what came back.
 */
static int gigabyte_laptop_set_devstate_typed(u32 method_id, u32 arg2, int *result,
					acpi_object_type *reply_type)
{
	union acpi_object *obj;
	acpi_status status;
	struct acpi_buffer buffer = { ACPI_ALLOCATE_BUFFER, NULL };
	struct acpi_buffer input = { sizeof(arg2), &arg2 };

	status = wmi_evaluate_method(WMI_METHOD_WMBD, 0, method_id, &input, &buffer);
	if (ACPI_FAILURE(status))
		return -EIO;

	obj = buffer.pointer;

	if (reply_type)
		*reply_type = obj ? obj->type : ACPI_TYPE_ANY;

	*result = (obj && obj->type == ACPI_TYPE_INTEGER) ? obj->integer.value : 0;

	kfree(obj);
	return 0;
}

static int gigabyte_laptop_set_devstate(u32 method_id, u32 arg2, int *result)
{
	return gigabyte_laptop_set_devstate_typed(method_id, arg2, result, NULL);
}

/* hwmon **************************************************/

/*
 * Helper method. Reverses byte order of fan RPM.
 * This is needed, since the embedded controller stores the value in big-endian
 * while x86 is little-endian.
 */
static u16 convert_fan_rpm(int val)
{
	u16 fan_rpm = val;
	return rol16(fan_rpm, 8);
}

/*
 * The embedded controller works in percent. FAN1, FAN2, FDTY and GDTY are
 * eight-bit fields the firmware treats as 0-100, and a read of FDTY saturates
 * there. hwmon's pwm attributes are 0-255, so scale in both directions rather
 * than passing values straight through: writing 128 unscaled asks the EC for
 * 128 percent, which it simply pins to full speed.
 */
#define EC_DUTY_MAX 100

static long ec_duty_to_pwm(int duty)
{
	return DIV_ROUND_CLOSEST(clamp_val(duty, 0, EC_DUTY_MAX) * 255, EC_DUTY_MAX);
}

static umode_t gigabyte_laptop_hwmon_is_visible(const void *data, enum hwmon_sensor_types type,
					u32 attr, int channel)
{
	struct gigabyte_laptop_wmi *gigabyte = platform_get_drvdata(platform_device);
	switch (type) {
		case hwmon_temp:
			switch (attr) {
				case hwmon_temp_input:
					return 0444;
				default:
					break;
			}
			break;
		case hwmon_fan:
			switch (attr) {
				case hwmon_fan_input:
					switch (channel) {
						case 2:
							if (gigabyte->has_three_fans || gigabyte->has_four_fans)
								return 0444;
							else
								return 0;
						case 3:
							if (gigabyte->has_four_fans)
								return 0444;
							else
								return 0;
						default:
							return 0444;
					}
				default:
					break;
			}
			break;
		case hwmon_pwm:
			switch (attr) {
				case hwmon_pwm_input:
				case hwmon_pwm_enable:
					// Read-only until a duty mechanism is found; see HWMON.md
					return 0444;
				default:
					break;
			}
			break;
		default:
			break;
	}
	return 0;
}

static int gigabyte_laptop_hwmon_read(struct device *dev, enum hwmon_sensor_types type,
					u32 attr, int channel, long *val)
{
	// Anything this switch does not reach is a channel hwmon should not have
	// asked for, so the default is an error rather than a silent success.
	int ret = -EOPNOTSUPP;
	int output;
	u8 result;
	u8 fan_channels[] = { FAN_CPU_RPM, FAN_GPU_RPM, FAN_THREE_RPM, FAN_FOUR_RPM };
	u8 fan_pwm_channels[] = { FAN_PWM, GPU_FAN_DUTY };

	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	switch (type) {
		case hwmon_temp:
			switch (channel) {
				case 0:
					ret = gigabyte_laptop_get_devstate(TEMP_CPU, &output);
					if (ret)
						break;
					*val = output * 1000;
					break;
				case 1:
					ret = gigabyte_laptop_get_devstate(TEMP_GPU, &output);
					if (ret)
						break;
					*val = output * 1000;
					break;
				case 2:
					// Motherboard temp cannot be read through WMI
					ret = ec_read(0x62, &result);
					if (ret)
						break;
					*val = result * 1000;
					break;
				default:
					*val = 0;
					ret = 0;
					break;
			}
			break;
		case hwmon_fan:
			ret = gigabyte_laptop_get_devstate(fan_channels[channel], &output);
			if (ret)
				break;
			// Gigabyte Gaming laptops store fan RPM in little-endian
			if (gigabyte_laptop_family_is("GIGABYTE GAMING") ||
				gigabyte_laptop_family_is("GIGABYTE AERO"))
				*val = output;
			else
				*val = convert_fan_rpm(output);
			break;
		case hwmon_pwm:
			switch (attr) {
				case hwmon_pwm_input:
					// FDTY and GDTY are the EC's live duty, in percent
					ret = gigabyte_laptop_get_devstate(fan_pwm_channels[channel], &output);
					if (ret)
						break;
					*val = ec_duty_to_pwm(output);
					break;
				case hwmon_pwm_enable:
					/*
					 * Fixed mode latches ADJF, a single bit, so it is full
					 * speed rather than a duty. Mode 4 is the one that holds
					 * both fans at a given duty. Everything else is an EC
					 * curve driven from temperature.
					 */
					if (gigabyte->fan_mode == 5)
						*val = GIGABYTE_FAN_CTRL_FULL_SPEED;
					else if (gigabyte->fan_mode == 4)
						*val = GIGABYTE_FAN_CTRL_MANUAL;
					else
						*val = GIGABYTE_FAN_CTRL_AUTO;
					ret = 0;
					break;
				default:
					break;
			}
			break;
		default:
			break;
	}
	return ret;
}


static const struct hwmon_channel_info *gigabyte_laptop_hwmon_info[] = {
	HWMON_CHANNEL_INFO(temp,
				HWMON_T_INPUT,
				HWMON_T_INPUT,
				HWMON_T_INPUT),
	HWMON_CHANNEL_INFO(fan,
				HWMON_F_INPUT,
				HWMON_F_INPUT,
				HWMON_F_INPUT,
				HWMON_F_INPUT),
	HWMON_CHANNEL_INFO(pwm,
				HWMON_PWM_INPUT | HWMON_PWM_ENABLE,
				HWMON_PWM_INPUT | HWMON_PWM_ENABLE),
	NULL
};

static const struct hwmon_ops gigabyte_laptop_hwmon_ops = {
	.read = gigabyte_laptop_hwmon_read,
	.is_visible = gigabyte_laptop_hwmon_is_visible,
};

static const struct hwmon_chip_info gigabyte_laptop_chip_info = {
	.ops = &gigabyte_laptop_hwmon_ops,
	.info = gigabyte_laptop_hwmon_info,
};

/* sysfs **************************************************/

/*
 * Fan mode.
 * 0 = normal fan mode
 * 1 = silent fan mode
 * 2 = gaming fan mode
 * 3 = custom fan mode
 * 4 = auto-maximum mode (requires custom mode)
 * 5 = fixed speed mode (requires custom mode)
 */
static int disable_custom_fan_mode(int mode)
{
	int ret, result;

	if (mode == 5) {
		ret = gigabyte_laptop_set_devstate(FAN_FIXED_MODE, 0, &result);
		if (ret)
			return ret;
	} else if (mode == 4) {
		// Auto-maximum mode can only be turned off through gaming or silent mode
		ret = gigabyte_laptop_set_devstate(FAN_GAMING_MODE, 0, &result);
		if (ret)
			return ret;
	}

	ret = gigabyte_laptop_set_devstate(FAN_CUSTOM_MODE, 0, &result);
	if (ret)
		return ret;

	return 0;
}

static int set_fan_mode(struct gigabyte_laptop_wmi *gigabyte, u32 fan_mode)
{
	int ret, result;

	if (fan_mode == FAN_FIXED_MODE || fan_mode == FAN_AUTO_MODE) {
		if (gigabyte->fan_mode < 3) { // If custom mode is off, enable it
			if (gigabyte->fan_mode > 0) {
				ret = gigabyte_laptop_set_devstate(fan_modes[gigabyte->fan_mode], 0, &result);
				if (ret)
					return ret;
			}

			ret = gigabyte_laptop_set_devstate(FAN_CUSTOM_MODE, 1, &result);
			if (ret)
				return ret;
		}

		if (gigabyte->fan_mode > 3) { // Fixed or auto mode active
			if (gigabyte->fan_mode == 4) {
				// Auto-maximum mode can only be turned off through gaming or silent mode
				ret = gigabyte_laptop_set_devstate(FAN_GAMING_MODE, 0, &result);
				if (ret)
					return ret;
			} else {
				ret = gigabyte_laptop_set_devstate(fan_modes[gigabyte->fan_mode], 0, &result);
				if (ret)
					return ret;
			}
		}

		if (fan_mode == FAN_AUTO_MODE) {
			ret = gigabyte_laptop_set_devstate(fan_mode, gigabyte->fan_custom_speed, &result);
			if (ret)
				return ret;
		} else {
			ret = gigabyte_laptop_set_devstate(fan_mode, 1, &result);
			if (ret)
				return ret;
		}
	} else if (fan_mode == FAN_CUSTOM_MODE) {
		if (gigabyte->fan_mode > 3) {
			/*
			 * Auto-maximum and fixed mode both sit on top of custom
			 * mode, so dropping to plain custom means clearing the one
			 * in effect. Reporting custom as already enabled and
			 * returning left the fans held while the caller went on to
			 * cache mode 3. Auto-maximum clears only through gaming or
			 * silent mode, as disable_custom_fan_mode() also relies on.
			 */
			if (gigabyte->fan_mode == 4)
				ret = gigabyte_laptop_set_devstate(FAN_GAMING_MODE, 0, &result);
			else
				ret = gigabyte_laptop_set_devstate(fan_modes[gigabyte->fan_mode], 0, &result);
			if (ret)
				return ret;
		} else if (gigabyte->fan_mode > 0) {
			ret = gigabyte_laptop_set_devstate(fan_modes[gigabyte->fan_mode], 0, &result);
			if (ret)
				return ret;
		}

		ret = gigabyte_laptop_set_devstate(FAN_CUSTOM_MODE, 1, &result);
		if (ret)
			return ret;
	} else {
		if (gigabyte->fan_mode >= 3) { // Disable custom mode first. Will revert to normal mode.
			ret = disable_custom_fan_mode(gigabyte->fan_mode);
			if (ret)
				return ret;
		} else if (gigabyte->fan_mode > 0) {
				ret = gigabyte_laptop_set_devstate(fan_modes[gigabyte->fan_mode], 0, &result);
				if (ret)
					return ret;
		}

		if (fan_mode != 0) {
			ret = gigabyte_laptop_set_devstate(fan_mode, 1, &result);
			if (ret)
				return ret;
		}
	}
	return 0;
}

static int set_fan_custom_speed(struct gigabyte_laptop_wmi *gigabyte, u32 speed)
{
	int ret, output;

	ret = gigabyte_laptop_set_devstate(FAN_CUSTOM_SPEED, speed, &output);
	if (ret)
		return ret;

	// On some models, FAN_CUSTOM_SPEED will only set CPU fan speed.
	if (gigabyte->dual_fan_speed_enabled) {
		ret = gigabyte_laptop_set_devstate(GPU_FAN_DUTY, speed, &output);
		if (ret)
			return ret;
	}

	gigabyte->fan_custom_speed = speed;
	return 0;
}

/*
 * Turbo is a fan mode plus a duty rather than a bit of its own, so a mode
 * change out from under it ends it. The duty has to go back first: auto-maximum
 * mode programs the fans from fan_custom_speed, so leaving turbo's 229 in place
 * would hand the next mode a duty the user never chose.
 *
 * Call with fan_lock held.
 */
static int end_fan_turbo(struct gigabyte_laptop_wmi *gigabyte)
{
	int ret, output;

	if (!gigabyte->fan_turbo)
		return 0;

	ret = set_fan_custom_speed(gigabyte, gigabyte->fan_turbo_saved_speed);
	if (ret)
		return ret;

	// Best effort, as in fan_turbo_store: the bit is not what holds the fans
	ret = gigabyte_laptop_set_devstate(FAN_TURBO, 0, &output);
	if (ret)
		pr_warn("Could not clear the turbo fan bit (%d)\n", ret);

	gigabyte->fan_turbo = 0;
	return 0;
}

static ssize_t fan_mode_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->fan_mode);
}

static ssize_t fan_mode_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret;
	unsigned int fan_mode = 0;
	u8 old_preset;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &fan_mode);
	if (ret) {
		pr_err("kstrtouint failed\n");
		return ret;
	}

	// Range-checked before anything reads the value, including the
	// already-set comparison below, which indexes fan_mode_presets
	if (fan_mode > 5) {
		pr_err("Invalid fan mode\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	guard(mutex)(&gigabyte->fan_lock);

	/*
	 * A direct write is as deliberate as a Mode key press, so the preset
	 * moves with it and a profile switch will not reclaim the fans. The
	 * custom modes have no preset of their own, so they fall back to auto,
	 * where the fan_mode > 2 rule protects them instead.
	 *
	 * This happens even when the mode is already the one asked for. Writing
	 * the mode you are already in is still a request to hold it, and leaving
	 * the preset on auto would let the next profile switch take it away.
	 */
	old_preset = gigabyte->fan_preset;
	gigabyte->fan_preset = fan_mode < ARRAY_SIZE(fan_mode_presets) ?
			fan_mode_presets[fan_mode] : FAN_PRESET_AUTO;

	if (gigabyte->fan_mode == fan_mode) {
		pr_warn("Already set to that fan mode\n");
		return count;
	}

	// Put the preset back if the transition does not happen, so it cannot
	// name a mode the fans are not in
	ret = end_fan_turbo(gigabyte);
	if (ret)
		goto restore_preset;

	ret = set_fan_mode(gigabyte, fan_modes[fan_mode]);
	if (ret)
		goto restore_preset;

	gigabyte->fan_mode = fan_mode;
	return count;

restore_preset:
	gigabyte->fan_preset = old_preset;
	return ret;
}

/*
 * Fan preset.
 *
 * Takes a name: auto, silent, normal or gaming. The Mode key cycles the same
 * ring in that order, wrapping from gaming back to auto.
 */
static int gigabyte_laptop_profile_to_fan_mode(enum platform_profile_option profile);
static int gigabyte_laptop_profile_to_perf_mode(enum platform_profile_option profile);

// Call with fan_lock held.
static int apply_fan_preset(struct gigabyte_laptop_wmi *gigabyte)
{
	int ret, mode;

	if (gigabyte->fan_preset == FAN_PRESET_AUTO) {
		/*
		 * A custom curve, a held duty and full speed are deliberate
		 * choices that outrank a policy selection, exactly as they do in
		 * gigabyte_laptop_profile_set(). Re-tethering then happens on the
		 * next profile switch, once the fans are back on an EC preset.
		 */
		if (gigabyte->fan_mode > 2)
			return 0;

		mode = gigabyte_laptop_profile_to_fan_mode(gigabyte->profile);
		if (mode < 0)
			return mode;
	} else {
		mode = fan_preset_modes[gigabyte->fan_preset];
	}

	if (gigabyte->fan_mode == mode)
		return 0;

	ret = end_fan_turbo(gigabyte);
	if (ret)
		return ret;

	ret = set_fan_mode(gigabyte, fan_modes[mode]);
	if (ret)
		return ret;

	gigabyte->fan_mode = mode;
	return 0;
}

static ssize_t fan_preset_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%s\n", fan_preset_names[gigabyte->fan_preset]);
}

static ssize_t fan_preset_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);
	int ret, preset;
	u8 old;

	preset = sysfs_match_string(fan_preset_names, buf);
	if (preset < 0) {
		pr_err("Invalid fan preset\n");
		return preset;
	}

	guard(mutex)(&gigabyte->fan_lock);

	// apply_fan_preset() reads the field, so set it first and put it back
	// if the transition fails, rather than reporting a preset that is not on
	old = gigabyte->fan_preset;
	gigabyte->fan_preset = preset;

	ret = apply_fan_preset(gigabyte);
	if (ret) {
		gigabyte->fan_preset = old;
		return ret;
	}

	return count;
}

/*
 * Reports the cache rather than reading 0x6B back, and that is deliberate.
 * WMBC 0x6B does implement the read, but it returns EC0.FAN1 -- the byte WMBD
 * 0x6B just assigned -- so a readback only confirms the ACPI store landed. It
 * cannot say whether the controller consumed the duty, which is the only thing
 * worth knowing here. charge_mode and charge_limit read their firmware back for
 * a reason that does not apply to this node: a charge ceiling is persistent
 * state the firmware clears on its own, a fan duty is not.
 */
static ssize_t fan_custom_speed_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->fan_custom_speed);
}

static ssize_t fan_custom_speed_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret;
	unsigned int speed;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &speed);
	if (ret)
		return ret;

	// The node's range is 0-255, as upstream documents it
	if (speed > 255) {
		pr_err("Invalid fan speed\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	guard(mutex)(&gigabyte->fan_lock);

	ret = set_fan_custom_speed(gigabyte, speed);
	if (ret)
		return ret;

	/*
	 * A duty write does not retire turbo, unlike a mode change: turbo is a
	 * duty *plus* latched fixed mode, and fixed mode is still latched, so
	 * the fans stay at full speed. Clearing the flag here left them pinned
	 * with nothing reporting it.
	 *
	 * Fixed mode also ignores the duty, so what the write really sets is
	 * where the fans land once turbo ends. Record it as the restore value
	 * so turbo-off honours the newest request rather than the pre-turbo one.
	 */
	if (gigabyte->fan_turbo)
		gigabyte->fan_turbo_saved_speed = speed;

	return count;
}

static ssize_t fan_pwm_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ret, output;

	ret = gigabyte_laptop_get_devstate(FAN_PWM, &output);
	if (ret)
		return ret;

	return sysfs_emit(buf, "%d\n", output);
}

/*
 * Charge mode.
 * 0 = default mode
 * 1 = custom mode
 */
/*
 * Read the firmware rather than the cache. WMBC implements 0x64, so there is no
 * reason to report a remembered value that cannot confirm a write landed and
 * goes stale if anything else moves BCPS. Falls back to the cache on a failed
 * read, which is better than claiming zero.
 *
 * Only bit 2 of BCPS selects the mode; the rest of the nibble is masked off
 * here rather than shifted into the answer.
 */
static ssize_t charge_mode_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);
	int output;

	/*
	 * Held because this *writes* the cache, not merely reads it. Without it
	 * a read that fetched the old value can land after a concurrent write
	 * updated both firmware and cache, leaving the cache stale -- and the
	 * battery's get_property serves that cache, so it would report a
	 * threshold the firmware does not have until the next write.
	 */
	guard(mutex)(&gigabyte->charge_lock);

	if (!gigabyte_laptop_get_devstate(CHARGING_MODE, &output))
		gigabyte->charge_mode = (output >> 2) & 1;

	return sysfs_emit(buf, "%d\n", gigabyte->charge_mode);
}

/*
 * Only bit 2 selects the mode, hence the shift. BCPS is a four-bit field and
 * this assigns all of it, so bits 0, 1 and 3 are zeroed on every write.
 * Harmless on this firmware, where BCPS reads 0 and nothing else is known to
 * use those bits -- but it is a blind write, not a read-modify-write, and
 * should become one if any of them ever turns out to mean something.
 *
 * Call with charge_lock held.
 */
/*
 * Enabling the mode latches whatever ceiling BCPC already holds, so a mode with
 * no usable ceiling is the one combination to refuse. BCPC has been seen reading
 * 0 after a power cycle, and enabling on top of that asks the EC to stop
 * charging at 0 % -- "never charge" is a plausible reading and nothing here can
 * rule it out.
 *
 * The floor is 1, not the charge_limit node's own 60: that floor keeps a sysfs
 * write inside the field width, while the battery ABI deliberately allows the
 * full 1-99 range and shares this path.
 *
 * The field is read rather than trusted from the cache, because the caller may
 * not have touched charge_limit since boot and this is the one place where
 * being wrong is expensive.
 */
static int set_charge_mode(struct gigabyte_laptop_wmi *gigabyte, u32 mode)
{
	int ret, output, limit;

	if (mode) {
		limit = gigabyte->charge_limit;
		if (!gigabyte_laptop_get_devstate(CHARGING_LIMIT, &output))
			limit = output;

		if (limit <= 0 || limit > 100) {
			pr_err("Refusing charge mode with a %d%% ceiling, write charge_limit first\n",
					limit);
			return -EINVAL;
		}

		gigabyte->charge_limit = limit;
	}

	ret = gigabyte_laptop_set_devstate(CHARGING_MODE, mode << 2, &output);
	if (ret)
		return ret;

	gigabyte->charge_mode = mode;
	return 0;
}

/* Call with charge_lock held. */
static int set_charge_limit(struct gigabyte_laptop_wmi *gigabyte, u32 limit)
{
	int ret, output;

	ret = gigabyte_laptop_set_devstate(CHARGING_LIMIT, limit, &output);
	if (ret)
		return ret;

	gigabyte->charge_limit = limit;
	return 0;
}

static ssize_t charge_mode_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret;
	unsigned int mode;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &mode);
	if (ret)
		return ret;

	if (mode > 1) {
		pr_err("Invalid charge mode\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	guard(mutex)(&gigabyte->charge_lock);

	ret = set_charge_mode(gigabyte, mode);
	if (ret)
		return ret;
	return count;
}

/*
 * Maximum charge limit. Only works if custom charge mode is enabled.
 * Can be set between 60 and 100 percent.
 */
/* Live and locked, for the same reasons as charge_mode. BCPC is a whole byte. */
static ssize_t charge_limit_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);
	int output;

	guard(mutex)(&gigabyte->charge_lock);

	if (!gigabyte_laptop_get_devstate(CHARGING_LIMIT, &output))
		gigabyte->charge_limit = output;

	return sysfs_emit(buf, "%d\n", gigabyte->charge_limit);
}

static ssize_t charge_limit_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret;
	unsigned int limit;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &limit);
	if (ret)
		return ret;

	if (limit > 100 || limit < 60) {
		pr_err("Invalid charge limit\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	guard(mutex)(&gigabyte->charge_lock);

	ret = set_charge_limit(gigabyte, limit);
	if (ret)
		return ret;

	return count;
}

/*
 * charge_control_end_threshold on the ACPI battery.
 *
 * This is the standard ABI for a charge ceiling -- what upower reads, what TLP
 * writes, and what a desktop's battery-limit setting is built on -- so the
 * ceiling belongs here as well as on this driver's own two nodes.
 *
 * It is exposed through power_supply_register_extension() from inside an ACPI
 * battery hook rather than by hanging a DEVICE_ATTR off the battery, for three
 * reasons. The filename then comes from the core, so it cannot drift from the
 * ABI. The callbacks are handed our drvdata explicitly, where a battery
 * attribute's show/store would receive the battery's device and this file's
 * universal dev_get_drvdata(dev) idiom would quietly return the wrong pointer.
 * And registering emits the KOBJ_CHANGE that udev needs to import upower's
 * CHARGE_LIMIT property.
 *
 * The ABI is one number where the firmware has two fields, so the mapping is
 * stated once here and nowhere else:
 *
 *   read   mode off            -> 100   (no ceiling is in force)
 *          mode on, 1..99      -> BCPC
 *          mode on, 0 or 100+  -> 100
 *   write  100 or 0            -> BCPC 100, then mode off
 *          1..99               -> BCPC v,   then mode on
 *          above 100           -> -EINVAL, nothing written
 *
 * Reporting a remembered-but-inactive ceiling is the one answer that actively
 * misleads, so "mode off" reads 100 whatever BCPC holds.
 *
 * Writes go BCPC first and BCPS second, always. Enabling the mode latches
 * whatever BCPC already holds, so the ceiling must be right before the enable
 * bit goes up -- and that order makes every partial failure fail safe: a
 * written ceiling with the mode still off enforces nothing, and an enable that
 * lands on 100 enforces nothing either.
 */
static const enum power_supply_property gigabyte_laptop_battery_props[] = {
	POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,
};

static int gigabyte_laptop_battery_get_property(struct power_supply *psy,
					const struct power_supply_ext *ext,
					void *data, enum power_supply_property psp,
					union power_supply_propval *val)
{
	struct gigabyte_laptop_wmi *gigabyte = data;

	if (psp != POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD)
		return -EINVAL;

	/*
	 * Served from the cache on purpose, never from a WMI read.
	 * power_supply_uevent() reads every property to build its environment
	 * and tolerates only a few errnos; anything else would abort the whole
	 * battery uevent and stop ordinary battery status reaching userspace.
	 * The cache is sound because no AML outside the two WMBD cases writes
	 * either field, so nothing can change them behind the driver.
	 */
	scoped_guard(mutex, &gigabyte->charge_lock) {
		if (!gigabyte->charge_mode || gigabyte->charge_limit <= 0 ||
			gigabyte->charge_limit >= 100)
			val->intval = 100;
		else
			val->intval = gigabyte->charge_limit;
	}

	return 0;
}

static int gigabyte_laptop_battery_set_property(struct power_supply *psy,
					const struct power_supply_ext *ext,
					void *data, enum power_supply_property psp,
					const union power_supply_propval *val)
{
	struct gigabyte_laptop_wmi *gigabyte = data;
	int ret, limit, mode;

	if (psp != POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD)
		return -EINVAL;

	if (val->intval < 0 || val->intval > 100)
		return -EINVAL;

	/*
	 * 0 means off rather than a 0 % ceiling, which would be meaningless.
	 * upower encodes "no limit" as start 0 / end 100 and clamps on the way
	 * in, so both ends of the range arrive here as a disable request.
	 *
	 * The driver's own charge_limit node refuses below 60. That floor has
	 * no firmware basis -- BCPC is a plain byte with no clamp anywhere in
	 * the AML -- so it is not inherited here, where the ABI defines the
	 * range instead.
	 */
	if (val->intval == 0 || val->intval == 100) {
		limit = 100;
		mode = 0;
	} else {
		limit = val->intval;
		mode = 1;
	}

	/*
	 * scoped_guard rather than guard, because power_supply_changed() must
	 * be reached with charge_lock released -- the same rule the Mode key's
	 * uevent follows. It schedules work that re-reads the properties, and
	 * get_property takes this lock.
	 */
	scoped_guard(mutex, &gigabyte->charge_lock) {
		ret = set_charge_limit(gigabyte, limit);
		if (ret)
			return ret;

		/*
		 * Only write the mode when it actually changes. Re-pointing an
		 * already-enabled ceiling at a new limit would otherwise repeat
		 * the mode write, and a failure there would report an error to
		 * userspace after the limit had already moved. The cache is
		 * sound to compare against because nothing outside the two WMBD
		 * cases writes BCPS.
		 */
		if (gigabyte->charge_mode != mode) {
			ret = set_charge_mode(gigabyte, mode);
			if (ret)
				return ret;
		}
	}

	/*
	 * Nothing in the power-supply sysfs or extension dispatch path emits
	 * this, so udev and upower would otherwise keep serving the previous
	 * threshold until some unrelated battery event came along.
	 */
	power_supply_changed(psy);

	return 0;
}

/*
 * Mandatory, not optional: the core adds write permission only when this
 * returns greater than zero. Omitting it yields a plausible-looking read-only
 * file that works under cat and fails only when something tries to write it.
 */
static int gigabyte_laptop_battery_prop_writeable(struct power_supply *psy,
					const struct power_supply_ext *ext,
					void *data, enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD;
}

static const struct power_supply_ext gigabyte_laptop_battery_ext = {
	.name			= GIGABYTE_LAPTOP_FILE,
	.properties		= gigabyte_laptop_battery_props,
	.num_properties		= ARRAY_SIZE(gigabyte_laptop_battery_props),
	.get_property		= gigabyte_laptop_battery_get_property,
	.set_property		= gigabyte_laptop_battery_set_property,
	.property_is_writeable	= gigabyte_laptop_battery_prop_writeable,
};

/*
 * Called for every ACPI battery, which on a one-battery machine means once --
 * but the name is not fixed, so do not key on it: this unit's is BAT1, not
 * BAT0. Attaching to whichever battery appears first is what the in-tree
 * drivers do, and the firmware's ceiling is a property of the charger rather
 * than of a particular pack.
 */
static int gigabyte_laptop_add_battery(struct power_supply *battery,
				struct acpi_battery_hook *hook)
{
	struct gigabyte_laptop_wmi *gigabyte =
		container_of(hook, struct gigabyte_laptop_wmi, battery_hook);

	int ret;

	if (gigabyte->battery)
		return 0;

	/*
	 * Record the battery only once registration has succeeded. Setting it
	 * first made a failed registration look like a successful one twice
	 * over: the hook could not retry on a later battery because the
	 * non-NULL pointer short-circuits above, and remove_battery would then
	 * unregister an extension that was never registered.
	 */
	ret = power_supply_register_extension(battery,
					&gigabyte_laptop_battery_ext,
					&gigabyte->pdev->dev, gigabyte);
	if (ret)
		return ret;

	gigabyte->battery = battery;
	return 0;
}

static int gigabyte_laptop_remove_battery(struct power_supply *battery,
				struct acpi_battery_hook *hook)
{
	struct gigabyte_laptop_wmi *gigabyte =
		container_of(hook, struct gigabyte_laptop_wmi, battery_hook);

	if (gigabyte->battery != battery)
		return 0;

	power_supply_unregister_extension(battery, &gigabyte_laptop_battery_ext);
	gigabyte->battery = NULL;
	return 0;
}

static ssize_t gpu_boost_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->gpu_boost);
}

static ssize_t gpu_boost_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret, output;
	unsigned int mode;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &mode);
	if (ret)
		return ret;

	gigabyte = dev_get_drvdata(dev);

	// TODO: Check for AORUS laptops with 4 modes

	/*
	 * The full 0-4 range the firmware implements. The upper two values are
	 * not boost levels: on Gigabyte Gaming firmware WMBD 0x51 dispatches as
	 *
	 *   0  NPCF.ACBT = 0       boost off
	 *   1  NPCF.ACBT = LCBT    boost on
	 *   2  no branch on this generation
	 *   3  Notify (GPP0.PEGP, 0x03) -- ACPI_NOTIFY_EJECT_REQUEST. The kernel
	 *      offlines the dGPU, unbinds its driver and calls _EJ0, which this
	 *      firmware provides: Linux exposes the device as ejectable at
	 *      /sys/bus/acpi/devices/LNXVIDEO:00, path \_SB.PCI0.GPP0.PEGP.
	 *   4  PEGP._ON(), WMOF = 0, Notify (PCI0, 0) -- restore and rescan.
	 *
	 * 3 and 4 are a matched detach/restore pair and both are exposed. The
	 * old code permitted 3 and rejected 4, leaving the destructive half
	 * reachable and the recovery unreachable; it also gated 3 on
	 * has_dgpu_ejector, which is derived from DMI rather than from the
	 * firmware and so cannot track which firmware carries the eject branch.
	 *
	 * The interlock that matters is in the firmware and applies whatever we
	 * do: the whole case body sits inside If (DPMF != 0x02), so a detach is
	 * refused outright while the internal panel is being driven by the dGPU.
	 * You cannot eject the GPU drawing your screen.
	 *
	 * What the firmware does not check is whether anything is *using* the
	 * GPU. That is the caller's business, so a detach is logged rather than
	 * refused -- refusing it would hide hardware this driver exists to
	 * expose. USAGE.md documents the sequence and the recovery.
	 */
	if (mode > 4) {
		pr_err("Invalid boost mode\n");
		return -EINVAL;
	}

	/*
	 * Warn, do not gate. The one thing worth checking before a detach is
	 * whether anything is using the GPU, and the kernel cannot answer that
	 * for an out-of-tree driver: the signals it does expose are bound-driver
	 * and runtime-PM state, both of which stay true for as long as the
	 * driver is loaded, so a gate on either would refuse every detach rather
	 * than the unsafe ones. The authority is the graphics stack's own tools.
	 *
	 * There is a real safety net below us. The kernel services the eject
	 * request by calling device_offline() first and aborts the removal if
	 * that fails, so this is an orderly teardown rather than a surprise
	 * removal. What nothing can catch is a driver that offlines cleanly
	 * while its users do not, which is why this says so out loud.
	 */
	/*
	 * Only claim detach/restore on firmware that has those branches. 0x51
	 * means something entirely different on the older ranges -- on
	 * Aero-15-Classic it writes PEG0.PEGP.TEMQ, a GPU temperature target, so
	 * 3 and 4 are a 3 C and a 4 C target there and this wording would be a
	 * lie in the kernel log. The values are still passed through, because
	 * upstream range-checks nothing here and narrowing them would remove
	 * behaviour on firmware where they do something.
	 */
	if (gigabyte->gaming_family) {
		if (mode == 3)
			pr_warn("dGPU detach requested. Anything holding the GPU -- a compositor, CUDA, a running game -- loses it now. Restore with 'echo 4' or a PCI rescan\n");
		else if (mode == 4)
			pr_info("dGPU restore requested\n");
	}

	ret = gigabyte_laptop_set_devstate(GPU_QBOOST, mode, &output);
	if (ret)
		return ret;

	/*
	 * 3 and 4 are actions, not states. Caching them would leave the node
	 * reporting "3" as though it were a boost level for the rest of the
	 * boot, so only the real levels update what this node reports.
	 */
	if (mode <= 2)
		gigabyte->gpu_boost = mode;

	return count;
}

/*
 * Performance mode (Gigabyte Gaming models).
 * Controls the discrete GPU's TGP/CTGP budget through the NPCF interface.
 * 0 = eco, 1 = balanced, 2 = boost
 *
 * Write-only in firmware: method 0xED exists under WMBD but has no WMBC
 * case, so this node reports the last value written rather than the mode
 * actually in effect. The firmware also resets the mode on every boot.
 */
static ssize_t perf_mode_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->perf_mode);
}

/* Caller holds power_lock. */
static int set_perf_mode(struct gigabyte_laptop_wmi *gigabyte, int mode)
{
	int ret, output;

	ret = gigabyte_laptop_set_devstate(PERF_MODE, mode, &output);
	if (ret)
		return ret;

	gigabyte->perf_mode = mode;
	return 0;
}

/*
 * Apply whatever tier the power preset names, or the current profile's tier
 * when it sits on AUTO. Caller holds power_lock.
 */
static int apply_power_preset(struct gigabyte_laptop_wmi *gigabyte)
{
	int mode = power_preset_modes[gigabyte->power_preset];

	if (mode < 0)
		mode = gigabyte_laptop_profile_to_perf_mode(gigabyte->profile);
	if (mode < 0)
		return 0; // profile this handler does not map; leave the tier alone

	return set_perf_mode(gigabyte, mode);
}

static ssize_t perf_mode_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret;
	unsigned int mode;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &mode);
	if (ret)
		return ret;

	/*
	 * 0-2 only. The firmware implements a mode 3, and it is not offered
	 * because it is a duplicate: measured on a GAMING A16 5TH it writes the
	 * same NPCF.ACBT as mode 2 and produced the same 70 W enforced limit.
	 * It does differ in NPCF.ATPP, which does not reach the GPU limit, so a
	 * mode-2/mode-3 difference could still exist on the APU side -- revisit
	 * only with data showing one.
	 */
	if (mode > 2) {
		pr_err("Invalid performance mode\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	guard(mutex)(&gigabyte->power_lock);

	ret = set_perf_mode(gigabyte, mode);
	if (ret)
		return ret;

	/*
	 * A direct write is as deliberate as naming a preset, so move the ring
	 * with it. Otherwise power_preset could report a tier that is not the
	 * one in effect -- the same rule fan_mode follows for fan_preset.
	 */
	gigabyte->power_preset = perf_mode_presets[mode];
	return count;
}

/*
 * GPU power preset. Mirrors fan_preset: anything but auto outranks the
 * platform profile, and auto re-tethers immediately.
 */
static ssize_t power_preset_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%s\n", power_preset_names[gigabyte->power_preset]);
}

static ssize_t power_preset_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);
	int ret, preset;
	u8 old;

	preset = sysfs_match_string(power_preset_names, buf);
	if (preset < 0) {
		pr_err("Invalid power preset\n");
		return preset;
	}

	guard(mutex)(&gigabyte->power_lock);

	// apply_power_preset() reads the field, so set it first and put it back
	// if the write fails, rather than reporting a tier that is not in effect
	old = gigabyte->power_preset;
	gigabyte->power_preset = preset;

	ret = apply_power_preset(gigabyte);
	if (ret) {
		gigabyte->power_preset = old;
		return ret;
	}

	return count;
}

/*
 * Dynamic boost (Gigabyte Gaming models).
 * Shifts power between the CPU and the discrete GPU under load.
 *
 * The EC takes this one inverted, so the value written is flipped. The node
 * itself reads and writes the conventional way around: 0 = off, 1 = on.
 */
static ssize_t dynamic_boost_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->dynamic_boost);
}

static ssize_t dynamic_boost_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret, output;
	unsigned int enable;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &enable);
	if (ret)
		return ret;

	if (enable > 1) {
		pr_err("Invalid dynamic boost mode\n");
		return -EINVAL;
	}

	ret = gigabyte_laptop_set_devstate(DYN_BOOST, !enable, &output);
	if (ret)
		return ret;

	gigabyte = dev_get_drvdata(dev);
	gigabyte->dynamic_boost = enable;
	return count;
}

/*
 * Turbo fan (Gigabyte Gaming models).
 *
 * Writing the EC's TFAN bit on its own does not hold the fans at full speed,
 * so turbo is engaged the way the firmware does it: program the highest safe
 * custom duty, then latch fixed fan mode. The fan mode and duty in use before
 * turbo was switched on are restored when it is switched off, and the TFAN bit
 * is cleared then in case the firmware set it behind our back.
 */
static ssize_t fan_turbo_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->fan_turbo);
}

static ssize_t fan_turbo_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret, output;
	unsigned int enable;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &enable);
	if (ret)
		return ret;

	if (enable > 1) {
		pr_err("Invalid turbo fan mode\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	guard(mutex)(&gigabyte->fan_lock);

	if (gigabyte->fan_turbo == enable)
		return count;

	if (enable) {
		gigabyte->fan_turbo_saved_mode = gigabyte->fan_mode;
		gigabyte->fan_turbo_saved_speed = gigabyte->fan_custom_speed;

		ret = set_fan_custom_speed(gigabyte, FAN_DUTY_MAX);
		if (ret)
			return ret;

		ret = set_fan_mode(gigabyte, FAN_FIXED_MODE);
		if (ret) {
			// Put the duty back, so a failed latch does not leave the fans pinned
			set_fan_custom_speed(gigabyte, gigabyte->fan_turbo_saved_speed);
			return ret;
		}

		gigabyte->fan_mode = 5;
	} else {
		/*
		 * Best effort. A stale TFAN bit is a far smaller problem than
		 * returning here would be, since that would skip the restore
		 * below and leave the fans latched at maximum duty.
		 */
		ret = gigabyte_laptop_set_devstate(FAN_TURBO, 0, &output);
		if (ret)
			pr_warn("Could not clear turbo fan bit (%d), restoring anyway\n", ret);

		// Restore the duty first, since auto mode programs the fans with it.
		ret = set_fan_custom_speed(gigabyte, gigabyte->fan_turbo_saved_speed);
		if (ret)
			return ret;

		/*
		 * Drop back to normal mode before restoring. set_fan_mode()
		 * transitions out of whatever fan_mode currently says, so going
		 * through normal mode gives the restore one well-defined starting
		 * point whatever the saved mode turns out to be. This is the path
		 * validated on hardware.
		 */
		ret = set_fan_mode(gigabyte, fan_modes[0]);
		if (ret)
			return ret;

		gigabyte->fan_mode = 0;

		if (gigabyte->fan_turbo_saved_mode) {
			ret = set_fan_mode(gigabyte,
					fan_modes[gigabyte->fan_turbo_saved_mode]);
			if (ret)
				return ret;

			gigabyte->fan_mode = gigabyte->fan_turbo_saved_mode;
		}
	}

	gigabyte->fan_turbo = enable;
	return count;
}

static ssize_t fan_curve_index_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->fan_curve_index);
}

static ssize_t fan_curve_index_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret;
	unsigned int index;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtouint(buf, 0, &index);
	if (ret)
		return ret;

	if (index >= FAN_CURVE_POINTS) {
		pr_err("Invalid fan curve index\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	gigabyte->fan_curve_index = index;
	return count;
}

static ssize_t fan_curve_data_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);
	int index = gigabyte->fan_curve_index;

	return sysfs_emit(buf, "%d %d\n", gigabyte->fan_curve.temperature[index],
		gigabyte->fan_curve.speed[index]);
}

static ssize_t fan_curve_data_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	int ret, output;
	u16 data;
	u32 payload;
	struct gigabyte_laptop_wmi *gigabyte;

	ret = kstrtou16(buf, 0, &data);
	if (ret)
		return ret;

	gigabyte = dev_get_drvdata(dev);
	// likely payload: speed, temp, index
	//payload = gigabyte->fan_curve.speed[gigabyte->fan_curve_index] << 16 | gigabyte->fan_curve.temperature[gigabyte->fan_curve_index] << 8 | (u8) gigabyte->fan_curve_index;
	payload = data << 8 | gigabyte->fan_curve_index;

	ret = gigabyte_laptop_set_devstate(FAN_INDEX_VALUE, payload, &output);
	if (ret)
		return ret;

	gigabyte->fan_curve.temperature[gigabyte->fan_curve_index] = data;
	gigabyte->fan_curve.speed[gigabyte->fan_curve_index] = data >> 8;
	return count;
}

static ssize_t battery_cycle_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ret, cyc1, cyc2;

	ret = gigabyte_laptop_get_devstate(BATT_CYCLE, &cyc1);
	if (ret)
		return ret;
	ret = gigabyte_laptop_get_devstate(BATT_CYCLE2, &cyc2);
	if (ret)
		return ret;

	return sysfs_emit(buf, "%d\n", max(cyc1, cyc2));
}

static ssize_t light_sensor_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ret, output_old;
	u8 output[4] = { };
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	if (gigabyte->light_sensor_method == LIGHT_SENSOR_NEW)
		ret = gigabyte_laptop_get_devstate_buf(gigabyte->light_sensor_method,
						output, sizeof(output));
	else
		ret = gigabyte_laptop_get_devstate(gigabyte->light_sensor_method, &output_old);
	if (ret)
		return ret;
	if (gigabyte->light_sensor_method == LIGHT_SENSOR_NEW)
		return sysfs_emit(buf, "%d %d %d %d\n", output[0], output[1], output[2], output[3]);
	else
		return sysfs_emit(buf, "%d\n", output_old);
}

static ssize_t power_on_time_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ret;
	u8 output[5] = { };

	ret = gigabyte_laptop_get_devstate_buf(POWER_ON_TIME, output, sizeof(output));
	if (ret)
		return ret;
	// year, month, day, hour, minute
	return sysfs_emit(buf, "%d %d %d %d %d\n", output[0], output[1], output[2], output[3], output[4]);
}

static ssize_t has_dgpu_ejector_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", gigabyte->has_dgpu_ejector);
}

/*
 * Debug node. Takes a method ID and an optional argument:
 *
 *	echo '0xE7'      > debug_method   # read method 0xE7 with argument 0
 *	echo '0xED 0x5A' > debug_method   # read method 0xED with argument 0x5A
 *
 * The argument matters. WMBC ends in Default { Return (Arg2) }, so a method ID
 * the firmware does not implement answers with whatever was passed in rather
 * than failing. Reading with a distinctive argument is the only way to tell an
 * unimplemented method from one that genuinely returns that value, which is
 * why the show handler flags the echo.
 */
static ssize_t debug_method_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	unsigned int method, arg = 0;
	int parsed;
	struct gigabyte_laptop_wmi *gigabyte;

	parsed = sscanf(buf, "%i %i", &method, &arg);
	if (parsed < 1) {
		pr_err("Expected a method ID, optionally followed by an argument\n");
		return -EINVAL;
	}

	if (method > 0xFF) {
		pr_err("Invalid method ID\n");
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);
	gigabyte->debug_method = method;
	gigabyte->debug_arg = (parsed > 1) ? arg : 0;
	return count;
}

static ssize_t debug_method_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int ret, output;
	bool echoed;
	acpi_object_type type = ACPI_TYPE_ANY;
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	ret = gigabyte_laptop_get_devstate_typed(gigabyte->debug_method,
					gigabyte->debug_arg, &output,
					sizeof(output), &type);
	if (ret)
		return ret;

	/*
	 * Two independent signals, because neither is complete on its own.
	 *
	 * An INTEGER reply is conclusive: the firmware has a case for this ID.
	 * A BUFFER reply is NOT conclusive the other way, and saying otherwise
	 * was wrong. WMBC ends in Default { Return (Arg2) } with Arg2 passed as
	 * a four-byte buffer, so an absent ID answers with a buffer -- but so
	 * does a case that genuinely returns one. On this firmware 0x63 is
	 * exactly that: it returns TEST, declared Buffer (0x05), the five CMOS
	 * bytes behind power_on_time. Reporting that as "not implemented" would
	 * be a false negative on a method that demonstrably works.
	 *
	 * The sentinel comparison is what separates them in practice: the echo
	 * hands back the argument, a real buffer almost never will. It is
	 * suggestive rather than conclusive, since a sentinel can collide with
	 * a real reading, which is why both are printed and neither is hidden.
	 *
	 * It is only meaningful for a non-INTEGER reply. Plenty of implemented
	 * methods legitimately answer with the value just passed -- read 0x65
	 * with the argument the ceiling already holds and BCPC hands the same
	 * number straight back -- so applying the echo note to an INTEGER reply
	 * labelled a working method "absent" alongside "implemented" in the same
	 * line.
	 */
	echoed = type != ACPI_TYPE_INTEGER && gigabyte->debug_arg &&
		output == (int)gigabyte->debug_arg;

	return sysfs_emit(buf, "method 0x%02x arg 0x%x -> 0x%x (%d) [%s]%s\n",
			gigabyte->debug_method, gigabyte->debug_arg, output, output,
			type == ACPI_TYPE_INTEGER ? "implemented" :
				"reply was not an integer: absent, or a method that returns a buffer",
			echoed ? " [argument echoed back -- probably absent]" : "");
}

/*
 * The write half, for trying WMBD methods deliberately rather than through a
 * node a fan daemon can drive:
 *
 *	echo '0x7D 1'  > debug_method_write   # set the EC's TFAN bit
 *	echo '0x46 50' > debug_method_write   # CPU fan duty, untried lead
 *
 * The write happens on store, not on show -- a read of a node must not have
 * side effects. Show reports what the last one did.
 *
 * This is a development aid and it is dangerous: a wrong duty can *stop* the
 * fans rather than slow them (method 0x70 at 100% does exactly that), and
 * poking the fan methods directly leaves the driver's cached fan_mode
 * describing a state the EC is no longer in. Re-read or rewrite fan_mode
 * afterwards. Root-only for that reason.
 */
static ssize_t debug_method_write_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	unsigned int method, arg = 0;
	int parsed, ret, output = 0;
	acpi_object_type type = ACPI_TYPE_ANY;
	struct gigabyte_laptop_wmi *gigabyte;

	parsed = sscanf(buf, "%i %i", &method, &arg);
	if (parsed < 1) {
		pr_err("Expected a method ID, optionally followed by an argument\n");
		return -EINVAL;
	}

	if (method > 0xFF) {
		pr_err("Invalid method ID\n");
		return -EINVAL;
	}

	/*
	 * 0x63 dereferences Arg2[0] through Arg2[0x04] and this setter passes
	 * four bytes, so the fifth read fails *after* four CMOS bytes have
	 * already been written — a half-written block in NVRAM that the
	 * firmware reads at the next boot. Refused until there is a wider
	 * setter. Snapshot the current five with power_on_time first.
	 */
	if (method == POWER_ON_TIME) {
		pr_err("Method 0x%02x needs a five-byte argument; refusing to write a partial CMOS block\n",
			POWER_ON_TIME);
		return -EINVAL;
	}

	gigabyte = dev_get_drvdata(dev);

	/*
	 * Held so a write cannot land in the middle of set_fan_mode()'s
	 * multi-step sequence. It does not keep the cached fan state honest —
	 * nothing can, for an arbitrary write — it only stops the two
	 * interleaving.
	 */
	scoped_guard(mutex, &gigabyte->fan_lock)
		ret = gigabyte_laptop_set_devstate_typed(method, arg, &output, &type);

	gigabyte->debug_write_method = method;
	gigabyte->debug_write_arg = (parsed > 1) ? arg : 0;
	gigabyte->debug_write_ret = ret;
	gigabyte->debug_write_result = ret ? 0 : output;
	gigabyte->debug_write_type = ret ? ACPI_TYPE_ANY : type;

	pr_info("debug write: method 0x%02x arg 0x%x -> ret %d, reply type %u, value 0x%x\n",
		gigabyte->debug_write_method, gigabyte->debug_write_arg,
		ret, gigabyte->debug_write_type, gigabyte->debug_write_result);

	if (ret)
		return ret;

	return count;
}

static ssize_t debug_method_write_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	if (gigabyte->debug_write_ret)
		return sysfs_emit(buf, "method 0x%02x arg 0x%x -> failed (%d)\n",
			gigabyte->debug_write_method, gigabyte->debug_write_arg,
			gigabyte->debug_write_ret);

	switch (gigabyte->debug_write_type) {
	case ACPI_TYPE_INTEGER:
		return sysfs_emit(buf,
			"method 0x%02x arg 0x%x -> wrote, replied 0x%x (%d)\n",
			gigabyte->debug_write_method, gigabyte->debug_write_arg,
			gigabyte->debug_write_result, gigabyte->debug_write_result);
	case ACPI_TYPE_BUFFER:
		/*
		 * Either a case that assigns and falls through without a
		 * Return, or Default { Return (Arg2) } echoing the argument
		 * because there is no case for this ID. Both land here, so say
		 * so rather than guess: check the EC field to tell them apart.
		 */
		return sysfs_emit(buf,
			"method 0x%02x arg 0x%x -> wrote, replied with a buffer (void case, or no case for this ID -- check the field)\n",
			gigabyte->debug_write_method, gigabyte->debug_write_arg);
	default:
		return sysfs_emit(buf,
			"method 0x%02x arg 0x%x -> wrote, no reply (void case)\n",
			gigabyte->debug_write_method, gigabyte->debug_write_arg);
	}
}

#define TOGGLE_DEVICE(_device, _id) \
static ssize_t _device##_toggle_show(struct device *dev, struct device_attribute *attr, char *buf) \
{ \
	int ret, output; \
	ret = gigabyte_laptop_get_devstate(_id, &output); \
	if (ret) \
		return ret; \
	return sysfs_emit(buf, "%d\n", output); \
} \
static DEVICE_ATTR_RO(_device##_toggle);
TOGGLE_DEVICE(usb_charge_s3, USB_SLEEP);
TOGGLE_DEVICE(usb_charge_s4, USB_HIBERNATE);

static DEVICE_ATTR_RW(fan_mode);
static DEVICE_ATTR_RW(fan_preset);
static DEVICE_ATTR_RW(fan_custom_speed);
static DEVICE_ATTR_RO(fan_pwm);
static DEVICE_ATTR_RW(charge_mode);
static DEVICE_ATTR_RW(charge_limit);
static DEVICE_ATTR_RW(gpu_boost);
static DEVICE_ATTR_RW(perf_mode);
static DEVICE_ATTR_RW(power_preset);
static DEVICE_ATTR_RW(dynamic_boost);
static DEVICE_ATTR_RW(fan_turbo);
static DEVICE_ATTR_RW(fan_curve_index);
static DEVICE_ATTR_RW(fan_curve_data);
static DEVICE_ATTR_RO(battery_cycle);
static DEVICE_ATTR_RO(light_sensor);
static DEVICE_ATTR_RO(power_on_time);
static DEVICE_ATTR_RO(has_dgpu_ejector);
static DEVICE_ATTR_ADMIN_RW(debug_method);
static DEVICE_ATTR_ADMIN_RW(debug_method_write);

static struct attribute *gigabyte_laptop_attributes[] = {
	&dev_attr_fan_mode.attr,
	&dev_attr_fan_preset.attr,
	&dev_attr_fan_custom_speed.attr,
	&dev_attr_fan_pwm.attr,
	&dev_attr_charge_mode.attr,
	&dev_attr_charge_limit.attr,
	&dev_attr_usb_charge_s3_toggle.attr,
	&dev_attr_usb_charge_s4_toggle.attr,
	&dev_attr_gpu_boost.attr,
	&dev_attr_perf_mode.attr,
	&dev_attr_power_preset.attr,
	&dev_attr_dynamic_boost.attr,
	&dev_attr_fan_turbo.attr,
	&dev_attr_fan_curve_index.attr,
	&dev_attr_fan_curve_data.attr,
	&dev_attr_battery_cycle.attr,
	&dev_attr_light_sensor.attr,
	&dev_attr_power_on_time.attr,
	&dev_attr_has_dgpu_ejector.attr,
	&dev_attr_debug_method.attr,
	&dev_attr_debug_method_write.attr,
	NULL
};

static umode_t gigabyte_laptop_sysfs_is_visible(struct kobject *kobj, struct attribute *attr, int idx)
{
	struct device *dev = kobj_to_dev(kobj);
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	// These use method IDs only present on Gigabyte Gaming firmware.
	// power_preset is here because it drives perf_mode and has nothing to
	// select elsewhere.
	if (attr == &dev_attr_perf_mode.attr ||
		attr == &dev_attr_power_preset.attr ||
		attr == &dev_attr_dynamic_boost.attr ||
		attr == &dev_attr_fan_turbo.attr)
		return gigabyte->gaming_family ? attr->mode : 0;

	/*
	 * Hide the nodes whose firmware methods this machine does not implement
	 * at all. Leaving them visible is worse than it looks: WMBC ends in
	 * Default { Return (Arg2) }, so a read of an absent ID comes back as the
	 * argument that was sent rather than as an error, and these handlers all
	 * read with 0. The node then reports a confident, permanent 0 that is
	 * indistinguishable from a real measurement -- a consumer reading
	 * battery_cycle would show "0 cycles" rather than "not supported".
	 *
	 * An absent node says that unambiguously. An erroring node does not: it
	 * reads as a transient fault to anything polling it.
	 *
	 * The firmware is asked directly rather than consulting a flag, because
	 * is_visible runs during sysfs_create_group(), before probe(), so
	 * anything probe works out is not available here yet.
	 */
	if (attr == &dev_attr_battery_cycle.attr)
		/*
		 * battery_cycle_show reads both IDs and returns on the first
		 * failure, so it is only useful when both are implemented. The
		 * gate has to be && for that reason, not ||.
		 */
		return (gigabyte_laptop_method_implemented(BATT_CYCLE) &&
			gigabyte_laptop_method_implemented(BATT_CYCLE2)) ? attr->mode : 0;

	if (attr == &dev_attr_usb_charge_s3_toggle.attr)
		return gigabyte_laptop_method_implemented(USB_SLEEP) ? attr->mode : 0;

	if (attr == &dev_attr_usb_charge_s4_toggle.attr)
		return gigabyte_laptop_method_implemented(USB_HIBERNATE) ? attr->mode : 0;

	/*
	 * The light sensor needs its own test rather than the plain
	 * implemented() check: its two methods answer with different ACPI
	 * types, and the newer one answers with a buffer, which is also what an
	 * absent method answers with.
	 */
	if (attr == &dev_attr_light_sensor.attr)
		return gigabyte_laptop_light_sensor_method() ? attr->mode : 0;

	return attr->mode;
}

static const struct attribute_group gigabyte_laptop_attr_group = {
	.is_visible = gigabyte_laptop_sysfs_is_visible,
	.attrs = gigabyte_laptop_attributes,
};

#define DMI_EXACT_MATCH_GIGABYTE_LAPTOP_FAMILY(name) \
	{ .matches = { \
		DMI_EXACT_MATCH(DMI_BOARD_VENDOR, "GIGABYTE"), \
		DMI_EXACT_MATCH(DMI_PRODUCT_FAMILY, name), \
	}}

#define DMI_EXACT_MATCH_GIGABYTE_LEGACY_DEVICE(name) \
	{ .matches = { \
		DMI_EXACT_MATCH(DMI_BOARD_VENDOR, "GIGABYTE"), \
		DMI_EXACT_MATCH(DMI_PRODUCT_NAME, name), \
	}}

// quirks
#define DMI_MATCH_GIGABYTE_LAPTOP_NAME(name) \
	{ .matches = { \
		DMI_EXACT_MATCH(DMI_BOARD_VENDOR, "GIGABYTE"), \
		DMI_MATCH(DMI_PRODUCT_NAME, name), \
	}}

static const struct dmi_system_id gigabyte_laptop_known_working_platforms[] = {
	DMI_EXACT_MATCH_GIGABYTE_LAPTOP_FAMILY("AERO"),
	DMI_EXACT_MATCH_GIGABYTE_LAPTOP_FAMILY("AORUS"),
	DMI_EXACT_MATCH_GIGABYTE_LAPTOP_FAMILY("GIGABYTE GAMING"),
	DMI_EXACT_MATCH_GIGABYTE_LAPTOP_FAMILY("GIGABYTE AERO"), // 16X, why
	// For older Aero models
	DMI_EXACT_MATCH_GIGABYTE_LAPTOP_FAMILY("Intel"),
	DMI_EXACT_MATCH_GIGABYTE_LEGACY_DEVICE("Aero 14"),
	DMI_EXACT_MATCH_GIGABYTE_LEGACY_DEVICE("P64V6"),
	DMI_EXACT_MATCH_GIGABYTE_LEGACY_DEVICE("P64V7"),
	{ }
};

static const struct dmi_system_id gigabyte_laptop_quirks_needed[] = {
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 15"),
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 16X"), // three fans
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 17"),  // three fans
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 17X"), // four fans
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS Master 18"), // four fans
	{ }
};

// Final models for AORUS 15/17/17X, only ones with dGPU ejector
static const struct dmi_system_id gigabyte_laptop_dgpu_ejector_needed[] = {
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 15 BKG"),
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 17 BSG"),
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 17 BKG"),
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 17X AZG"),
	DMI_MATCH_GIGABYTE_LAPTOP_NAME("AORUS 17X AXG"),
	{ }
};

static int find_str(const char *dmi_name, const char *dmi_sub) {
	char *pos = strstr(dmi_name, dmi_sub);
	if (pos) {
		pr_info("Found %s in %s\n", dmi_sub, dmi_name);
		return 0;
	}
	return -1;
}

static int check_sku(const char *dmi_sku, const char *end) {
	size_t length;

	// DMI fields can be absent, and an empty one would index backwards
	if (!dmi_sku || !*dmi_sku)
		return -1;

	length = strlen(dmi_sku);

	char last_char = dmi_sku[length - 1];
	if (last_char == end[0]) {
		pr_info("Found %s in %s\n", end, dmi_sku);
		return 0;
	}
	return -1;
}

/* Platform profile ***************************************/

/*
 * Profiles select a fan policy, not a GPU power budget. The budget was the
 * original plan, but this firmware's TGP path is unreachable: nvidia-powerd
 * cannot read the SBIOS power-limit table, so the NPCF values perf_mode writes
 * are never applied. Fan policy is entirely within the EC and works.
 *
 * tuned already asks for these three names, so the desktop drives them with no
 * further configuration.
 */
/*
 * Measured on a GAMING A16 5TH: the EC's normal and gaming curves both ramp the
 * fans hard, so the mapping is shifted one notch quieter than the obvious one.
 * Power saver and balanced both get silent, and performance gets normal.
 *
 * Gaming is deliberately left off this list. It is the loudest preset and is
 * reserved as its own axis, for the Mode key to cycle fan presets directly
 * rather than through a battery profile.
 *
 * low-power and quiet both appear because the two consumers prefer different
 * names: tuned's powersave profile asks for "low-power|quiet" and takes the
 * first available, while tuned's power-profiles-daemon shim only recognises
 * low-power, balanced and performance when translating back for the desktop
 * indicator. Offering both keeps that translation working in each direction.
 */
static int gigabyte_laptop_profile_to_fan_mode(enum platform_profile_option profile)
{
	switch (profile) {
		case PLATFORM_PROFILE_LOW_POWER:
		case PLATFORM_PROFILE_QUIET:
		case PLATFORM_PROFILE_BALANCED:
			return 1; // silent
		case PLATFORM_PROFILE_PERFORMANCE:
			return 0; // normal
		default:
			return -EOPNOTSUPP;
	}
}

/*
 * The GPU half of the mapping, one tier per profile. Measured on a GAMING A16
 * 5TH: perf_mode 0/1/2 set enforced.power.limit to 50/60/70 W against a 50 W
 * VBIOS default.
 *
 * Unlike the fan mapping this is not shifted a notch quieter, because GPU power
 * costs nothing when the GPU is idle -- there is no equivalent of the EC
 * ramping the fans hard. Balanced therefore gets the middle tier rather than
 * sharing the bottom one with the two low-power names.
 *
 * On battery every one of these writes lands and does nothing: the firmware
 * withholds the DC power-limit table from nvidia-powerd and disables the DC
 * Dynamic Boost controller, so there is no consumer to apply the change. That
 * is above this driver and cannot be fixed here; USAGE.md says so.
 */
static int gigabyte_laptop_profile_to_perf_mode(enum platform_profile_option profile)
{
	switch (profile) {
		case PLATFORM_PROFILE_LOW_POWER:
		case PLATFORM_PROFILE_QUIET:
			return 0; // eco, 50 W
		case PLATFORM_PROFILE_BALANCED:
			return 1; // 60 W
		case PLATFORM_PROFILE_PERFORMANCE:
			return 2; // boost, 70 W
		default:
			return -EOPNOTSUPP;
	}
}

static int gigabyte_laptop_profile_probe(void *drvdata, unsigned long *choices)
{
	struct gigabyte_laptop_wmi *gigabyte = drvdata;

	set_bit(PLATFORM_PROFILE_LOW_POWER, choices);
	set_bit(PLATFORM_PROFILE_QUIET, choices);
	set_bit(PLATFORM_PROFILE_BALANCED, choices);
	set_bit(PLATFORM_PROFILE_PERFORMANCE, choices);

	/*
	 * Start from the fan mode the firmware is already in, as dell-pc.c does.
	 * Three profiles share the silent preset, so balanced is the one reported
	 * for it: it is the neutral choice and what tuned asks for by default.
	 * Anything that is not a preset this handler drives also reports balanced,
	 * since the profile is not what is holding the fans in that case.
	 */
	if (gigabyte->fan_mode == 0)
		gigabyte->profile = PLATFORM_PROFILE_PERFORMANCE;
	else
		gigabyte->profile = PLATFORM_PROFILE_BALANCED;

	return 0;
}

static int gigabyte_laptop_profile_get(struct device *dev,
				enum platform_profile_option *profile)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	*profile = gigabyte->profile;
	return 0;
}

static int gigabyte_laptop_profile_set(struct device *dev,
				enum platform_profile_option profile)
{
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);
	enum platform_profile_option old_profile;
	int ret = 0, mode;

	mode = gigabyte_laptop_profile_to_fan_mode(profile);
	if (mode < 0)
		return mode;

	/*
	 * Two axes, two locks, applied in sequence rather than nested. Fans and
	 * GPU power are independent: holding one must not freeze the other, and
	 * a single lock spanning both would mean holding a fan lock across a
	 * GPU write for no reason.
	 */
	scoped_guard(mutex, &gigabyte->fan_lock) {
		/*
		 * Leave the fans alone when the user holds them. The Mode key's
		 * fan preset is one such hold; a custom curve, a held duty and
		 * full speed are the others. All are deliberate, and a profile
		 * switch arriving from the desktop should not pull them out from
		 * under whatever set them. The profile applies on the next switch
		 * once the fans are back on an EC preset and the ring is on auto.
		 */
		if (gigabyte->fan_preset == FAN_PRESET_AUTO &&
			gigabyte->fan_mode <= 2 &&
			gigabyte->fan_mode != mode) {
			ret = set_fan_mode(gigabyte, fan_modes[mode]);
			if (ret)
				return ret;

			gigabyte->fan_mode = mode;
		}
	}

	/*
	 * The profile has to be recorded before the GPU half runs, because
	 * apply_power_preset() reads it to find the tier when the ring is on
	 * auto. Recording it here rather than at the end also means a profile
	 * whose fans were held is still remembered, which is the behaviour the
	 * fan-hold path always had.
	 */
	old_profile = gigabyte->profile;
	gigabyte->profile = profile;

	/*
	 * perf_mode exists only on Gigabyte Gaming firmware, so there is no GPU
	 * tier to apply elsewhere.
	 */
	if (!gigabyte->gaming_family)
		return 0;

	scoped_guard(mutex, &gigabyte->power_lock) {
		// Anything but auto is a deliberate hold; the profile is recorded
		// above and applies on the next switch once the ring is back
		if (gigabyte->power_preset == POWER_PRESET_AUTO) {
			ret = apply_power_preset(gigabyte);
			if (ret)
				break;
		}
	}

	/*
	 * A failed GPU write is reported to the caller rather than only logged,
	 * for the same reason the fan half returns its errors: silently
	 * succeeding on a half-applied switch is worse than an error, and
	 * profile_get must not report a profile that did not fully land. The
	 * recorded profile is rolled back for that reason.
	 *
	 * The fan change has already happened and is not undone -- unwinding it
	 * could fail in turn, and the fan state it would restore is what the
	 * next successful switch overwrites anyway. The log line says so, since
	 * the return code alone cannot.
	 */
	if (ret) {
		gigabyte->profile = old_profile;
		pr_warn("Profile switch applied fan policy but not the GPU tier: %d\n",
			ret);
		return ret;
	}

	return 0;
}

static const struct platform_profile_ops gigabyte_laptop_profile_ops = {
	.probe = gigabyte_laptop_profile_probe,
	.profile_get = gigabyte_laptop_profile_get,
	.profile_set = gigabyte_laptop_profile_set,
};

/* Keyboard backlight *************************************/

/*
 * The backlight is a two-level LED exposed through the LED class rather than a
 * sysfs attribute of our own, because that is the only route the desktop
 * already watches: upower matches on subsystem "leds" with a name globbing
 * *kbd_backlight*, exports it on org.freedesktop.UPower.KbdBacklight, and
 * Powerdevil drives KDE's slider from there. A platform attribute reaches none
 * of that. systemd's 99-systemd.rules gives save and restore across reboots for
 * free from the same match.
 *
 * There is deliberately no second writable node over KBLL. The class device's
 * own brightness file is already a plain numeric node for scripting.
 */
static int gigabyte_laptop_kbd_brightness_set(struct led_classdev *led_cdev,
					enum led_brightness value)
{
	int output;

	/*
	 * brightness_set_blocking, not brightness_set: this sleeps. The write
	 * evaluates AML through wmi_evaluate_method(), and KBLL lives in a
	 * Field(..., Lock, ...) region so each access takes the ACPI global
	 * lock as well.
	 *
	 * No range check: the LED core clamps to max_brightness before calling,
	 * which is the only clamp there is -- the firmware has none.
	 */
	return gigabyte_laptop_set_devstate(KBD_BRIGHTNESS, value, &output);
}

/*
 * Mandatory in practice, not an optimisation. Fn+Space is handled inside the
 * embedded controller, so the level moves without us writing it, and a cached
 * value would be stale the first time the user looked. On a failed read, keep
 * reporting the last known value rather than claiming zero.
 */
static enum led_brightness gigabyte_laptop_kbd_brightness_get(struct led_classdev *led_cdev)
{
	int ret, output;

	ret = gigabyte_laptop_get_devstate(KBD_BRIGHTNESS, &output);
	if (ret)
		return led_cdev->brightness;

	return clamp_val(output, 0, KBD_BRIGHTNESS_MAX);
}

/*
 * The EC publishes its own level as a 0xF6 event when Fn+Space is pressed, with
 * the new level in the state byte. Telling the LED core means KDE's slider
 * follows the key instead of going stale, which is the whole reason
 * LED_BRIGHT_HW_CHANGED is set. Without a real event to call this from the flag
 * would create a permanently stale attribute, so the two belong together.
 */
static void gigabyte_laptop_kbd_brightness_changed(u8 level)
{
	struct gigabyte_laptop_wmi *gigabyte;

	if (!platform_device)
		return;

	gigabyte = platform_get_drvdata(platform_device);
	if (!gigabyte || !gigabyte->has_kbd_backlight)
		return;

	level = clamp_val(level, 0, KBD_BRIGHTNESS_MAX);

	gigabyte->kbd_led.brightness = level;
	led_classdev_notify_brightness_hw_changed(&gigabyte->kbd_led, level);
}

/* Hotkey events ******************************************/

/*
 * The GiMate and Mode keys emit no i8042 scancode and nothing on the ENE
 * i2c-HID pipe. They arrive as WMI events instead:
 *
 *	_Q45 -> SMGR(WEVN, WEVS) -> WMBC(0, 0x03, n) -> Notify (AMW0, 0xD2)
 *
 * _WED then hands back {WEVN, WEVS, 0xBB, 0xCC}, so byte 0 is the event number
 * used as the scancode below. Measured on a GAMING A16 5TH: GiMate is 0xCE and
 * Mode (Fn+F7) is 0xCC, both with state 0x00.
 *
 * The alternative path the firmware offers, _Q63 -> Notify (GAPD, 0xCF) on
 * GBT0005, never fires for these keys on this machine. Its handler is kept as
 * a watcher, both because GBT0005 does report itself present and because it is
 * how other models in this family may deliver the same keys.
 */
#define GBT_ACPI_DEVICE "GBT0005"

/*
 * GiMate is reported as a programmable key, so GNOME and KDE can bind it to
 * whatever the user wants.
 *
 * Mic mute (0xC8) gets the standard keycode, because unlike GiMate it is a key
 * with one obvious meaning that every desktop already handles. Identified on a
 * GAMING A16 5TH by pressing it; the firmware does not name it, but the older
 * Aero/AORUS DSDTs assign the same event number in AML -- _Q41, between _Q40
 * (audio mute, which carries the MUTE field) and _Q42 (Fn-lock). It passes a
 * constant Zero rather than a field, which is why the state byte is always 0:
 * the controller announces the press and tracks no state of its own.
 *
 * Note that this key ALSO emits KEY_F15 from the i8042 keyboard, measured with
 * libinput on a GA65TH -- so it arrives twice, once from each path, and only
 * one of them is ours. Harmless while nothing binds F15, but a user who bound
 * F15 to mute the microphone before this mapping existed will now get two
 * toggles per press, which cancel out. GiMate does NOT do this: it emits no
 * scancode at all, which is why it needs the driver to report it.
 *
 * Mode (Fn+F7) is deliberately absent: it cycles the fan preset in the kernel
 * instead, which is what it does on Windows and the only way to reach gaming
 * mode without a terminal. gigabyte_laptop_wmi_notify() intercepts it before
 * the keymap is consulted, so it reports no keycode at all.
 *
 * Not mapped, and deliberately: 0xEF is the lid, which the kernel already
 * services through LID0 -- the firmware sends both, so mapping it here would
 * duplicate an event the ACPI button driver has already delivered.
 */
#define GIGABYTE_EVENT_MODE 0xCC

static const struct key_entry gigabyte_laptop_keymap[] = {
	{ KE_KEY, 0xC8, { KEY_MICMUTE } },	// microphone mute
	{ KE_KEY, 0xCE, { KEY_PROG1 } },	// GiMate
	{ KE_END, 0 }
};

static void gigabyte_laptop_cycle_fan_preset(void)
{
	struct gigabyte_laptop_wmi *gigabyte;
	char env[48];
	u8 preset, old;
	int ret;

	// The event driver outlives neither, but it is registered separately
	if (!platform_device)
		return;

	gigabyte = platform_get_drvdata(platform_device);
	if (!gigabyte)
		return;

	scoped_guard(mutex, &gigabyte->fan_lock) {
		old = gigabyte->fan_preset;
		preset = (old + 1) % FAN_PRESET_COUNT;

		gigabyte->fan_preset = preset;
		ret = apply_fan_preset(gigabyte);
		if (ret)
			gigabyte->fan_preset = old;
	}

	if (ret) {
		pr_warn("Mode key: could not select the %s fan preset (%d)\n",
			fan_preset_names[preset], ret);
		return;
	}

	pr_info("Mode key: fan preset %s\n", fan_preset_names[preset]);

	// So a desktop can poll() the attribute and show what the key just did
	sysfs_notify(&gigabyte->pdev->dev.kobj, NULL, "fan_preset");

	/*
	 * And a broadcast for consumers that never opened the file: udev rules,
	 * RUN+=, systemd device units.
	 *
	 * The value travels with the event rather than being re-read, because
	 * fan_preset can move again before a consumer gets round to reading it
	 * -- three quick presses can leave a slow reader seeing one event and
	 * the final value, with the intermediate presets never observed. preset
	 * was captured inside the lock above, so the event *is* the value.
	 * ACTION, DEVPATH, SUBSYSTEM and SEQNUM come from the core.
	 *
	 * Emitted here and nowhere else, deliberately. A sysfs write to
	 * fan_preset or fan_mode is a change the writer already knows about,
	 * and both hold fan_lock for their whole body, where this call must not
	 * run: it allocates GFP_KERNEL and can enter reclaim. A key press is
	 * the one change userspace has no other way to see, and by here the
	 * lock is released and the failure path has already returned.
	 *
	 * The return value is dropped. Under memory pressure a lost cosmetic
	 * notification is not worth a warning.
	 */
	snprintf(env, sizeof(env), "GIGABYTE_FAN_PRESET=%s", fan_preset_names[preset]);
	kobject_uevent_env(&gigabyte->pdev->dev.kobj, KOBJ_CHANGE,
			(char *[]){ env, NULL });
}

static struct input_dev *gigabyte_laptop_input;

static int gigabyte_laptop_input_setup(struct device *parent)
{
	struct input_dev *input;
	int err;

	input = input_allocate_device();
	if (!input)
		return -ENOMEM;

	input->name = "Gigabyte laptop hotkeys";
	input->phys = GIGABYTE_LAPTOP_FILE "/input0";
	input->id.bustype = BUS_HOST;
	input->dev.parent = parent;

	err = sparse_keymap_setup(input, gigabyte_laptop_keymap, NULL);
	if (err)
		goto fail;

	err = input_register_device(input);
	if (err)
		goto fail;

	gigabyte_laptop_input = input;
	return 0;

fail:
	input_free_device(input);
	return err;
}

static void gigabyte_laptop_input_destroy(void)
{
	if (!gigabyte_laptop_input)
		return;

	input_unregister_device(gigabyte_laptop_input);
	gigabyte_laptop_input = NULL;
}

static acpi_handle gigabyte_laptop_gapd_handle;

static void gigabyte_laptop_acpi_notify(acpi_handle handle, u32 event, void *data)
{
	pr_info("ACPI event: " GBT_ACPI_DEVICE " notify 0x%02x\n", event);
}

static void gigabyte_laptop_install_acpi_notify(void)
{
	struct acpi_device *adev;
	acpi_status status;

	adev = acpi_dev_get_first_match_dev(GBT_ACPI_DEVICE, NULL, -1);
	if (!adev) {
		pr_info("No " GBT_ACPI_DEVICE " device, skipping its notify handler\n");
		return;
	}

	status = acpi_install_notify_handler(adev->handle, ACPI_DEVICE_NOTIFY,
					gigabyte_laptop_acpi_notify, NULL);
	if (ACPI_FAILURE(status))
		pr_warn("Could not watch " GBT_ACPI_DEVICE " for events\n");
	else
		gigabyte_laptop_gapd_handle = adev->handle;

	acpi_dev_put(adev);
}

static void gigabyte_laptop_remove_acpi_notify(void)
{
	if (!gigabyte_laptop_gapd_handle)
		return;

	acpi_remove_notify_handler(gigabyte_laptop_gapd_handle, ACPI_DEVICE_NOTIFY,
				gigabyte_laptop_acpi_notify);
	gigabyte_laptop_gapd_handle = NULL;
}

/*
 * WMI events arrive as the buffer _WED returns, which the DSDT fills from
 * DEVS: byte 0 is the EC's event number and byte 1 its state.
 */
static void gigabyte_laptop_wmi_notify(struct wmi_device *wdev, union acpi_object *obj)
{
	u8 code;

	if (!obj || obj->type != ACPI_TYPE_BUFFER || obj->buffer.length < 1) {
		pr_warn("WMI event carried no usable payload\n");
		return;
	}

	code = obj->buffer.pointer[0];

	if (code == GIGABYTE_EVENT_MODE) {
		gigabyte_laptop_cycle_fan_preset();
		return;
	}

	if (code == KBD_BRIGHTNESS) {
		gigabyte_laptop_kbd_brightness_changed(
			obj->buffer.length >= 2 ? obj->buffer.pointer[1] : 0);
		return;
	}

	if (!gigabyte_laptop_input) {
		pr_info("WMI event 0x%02x arrived with no input device\n", code);
		return;
	}

	/*
	 * Log only what the keymap does not cover, so an event number this
	 * firmware uses but we have not seen still shows up and can be added.
	 */
	if (!sparse_keymap_report_event(gigabyte_laptop_input, code, 1, true))
		pr_info("Unrecognised WMI event 0x%02x (state 0x%02x)\n", code,
			obj->buffer.length >= 2 ? obj->buffer.pointer[1] : 0);
}

static const struct wmi_device_id gigabyte_laptop_event_ids[] = {
	{ WMI_EVENT, NULL },
	{ }
};

static struct wmi_driver gigabyte_laptop_event_driver = {
	.driver = {
		.name = "gigabyte-laptop-events",
	},
	.id_table = gigabyte_laptop_event_ids,
	.notify = gigabyte_laptop_wmi_notify,
	// This firmware's events carry a 4-byte buffer, but tolerate none
	.min_event_size = 0,
};

static bool gigabyte_laptop_event_driver_live;

/* Driver init ********************************************/

/*
 * Called before hwmon registration, not from probe. hwmon asks
 * gigabyte_laptop_hwmon_is_visible() which channels to expose as it registers,
 * so these two flags have to be set by then or fan3_input and fan4_input never
 * appear on the three- and four-fan AORUS models.
 */
static void gigabyte_laptop_detect_fan_count(struct gigabyte_laptop_wmi *gigabyte)
{
	if (!dmi_check_system(gigabyte_laptop_quirks_needed))
		return;

	if ((find_str(dmi_get_system_info(DMI_PRODUCT_NAME), "AORUS 17X") == 0 &&
		dmi_get_bios_year() >= 2023) ||
		find_str(dmi_get_system_info(DMI_PRODUCT_NAME), "AORUS Master 18") == 0) {
		gigabyte->has_four_fans = 1;
	}
	else if (find_str(dmi_get_system_info(DMI_PRODUCT_NAME), "AORUS 16X") == 0 ||
		(find_str(dmi_get_system_info(DMI_PRODUCT_NAME), "AORUS 17") == 0 &&
		dmi_get_bios_year() >= 2023)) {
		gigabyte->has_three_fans = 1;
	}
}

static int gigabyte_laptop_probe(struct device *dev)
{
	int ret, output;
	u8 result;
	struct gigabyte_laptop_wmi *gigabyte = dev_get_drvdata(dev);

	// Older devices are using a different method ID for silent fan mode.
	// In that case, newer devices won't return anything when using that ID.
	if (gigabyte_laptop_family_is("GIGABYTE GAMING") ||
		gigabyte_laptop_family_is("GIGABYTE AERO") ||
		gigabyte_laptop_family_is("AORUS")) {
		pr_info("Skipping silent fan mode ID check, this only applies to old models\n");
		gigabyte->fan_silent_method = FAN_SILENT_MODE;
		goto obtain_fan_mode;
	}

	// A failed read leaves output untouched, so check ret before trusting it
	ret = gigabyte_laptop_get_devstate(FAN_SILENT_OLD, &output);
	if (ret || output < 0) { // -1, or no answer at all, on newer devices
		pr_info("Newer model detected, using new silent fan mode ID\n");
		gigabyte->fan_silent_method = FAN_SILENT_MODE;
	}
	else { // 0 on older devices
		pr_info("Older model detected, using old ID\n");
		gigabyte->fan_silent_method = FAN_SILENT_OLD;
	}

obtain_fan_mode:
	// Set silent fan mode ID.
	fan_modes[1] = gigabyte->fan_silent_method;

	/*
	 * Get current fan mode.
	 *
	 * None of these reads is worth refusing to load over. The sensors are
	 * already registered by the time probe runs, so a firmware that answers
	 * some methods and not others should still give the user working fans
	 * and temperatures. Every failure below therefore warns and falls back
	 * to normal mode rather than aborting.
	 */
	ret = gigabyte_laptop_get_devstate(gigabyte->fan_silent_method, &output);
	if (ret)
		goto fan_mode_unknown;
	else if (output) {
		gigabyte->fan_mode = 1;
		goto obtain_custom_fan_speed;
	}
	ret = gigabyte_laptop_get_devstate(FAN_GAMING_MODE, &output);
	if (ret)
		goto fan_mode_unknown;
	else if (output) {
		gigabyte->fan_mode = 2;
		goto obtain_custom_fan_speed;
	}
	ret = gigabyte_laptop_get_devstate(FAN_CUSTOM_MODE, &output);
	if (ret)
		goto fan_mode_unknown;
	else if (output) {
		// Auto-maximum mode can't be read through WMI, so read EC register containing it
		ret = ec_read(0xD, &result);
		if (ret)
			goto fan_mode_unknown;
		output = (result >> 7) & 0x1;
		if (output) {
			gigabyte->fan_mode = 4;
			goto obtain_custom_fan_speed;
		}
		ret = gigabyte_laptop_get_devstate(FAN_FIXED_MODE, &output);
		if (ret)
			goto fan_mode_unknown;
		else if (output)
			gigabyte->fan_mode = 5;
		else
			gigabyte->fan_mode = 3;
		goto obtain_custom_fan_speed;
	}
	// If all checks return 0, we are most likely in normal fan mode
	gigabyte->fan_mode = 0;
	goto obtain_custom_fan_speed;

fan_mode_unknown:
	pr_warn("Could not determine fan mode (%d), assuming normal\n", ret);
	gigabyte->fan_mode = 0;

obtain_custom_fan_speed:
	ret = gigabyte_laptop_get_devstate(FAN_CUSTOM_SPEED, &output);
	if (ret)
		pr_info("Custom fan speed unreadable on this firmware\n");
	else if (output)
		gigabyte->fan_custom_speed = output;

	/*
		Newer models (VB and later) can have their fan speeds changed separately.
		We should check if the model we are using supports this, and if not, we
		will simply fall back to the old way of setting the fan speed.
	*/
	if (dmi_get_bios_year() >= 2020) {
		// Since VA/VB/VC models have 2020 as BIOS year, check SKU
		if (!check_sku(dmi_get_system_info(DMI_PRODUCT_SKU), "B") ||
			!check_sku(dmi_get_system_info(DMI_PRODUCT_SKU), "C")) {
			pr_info("Dual fan speed control required\n");
			gigabyte->dual_fan_speed_enabled = 1;
		}
		else if (dmi_get_bios_year() > 2020) { // VD and later
			pr_info("Dual fan speed control required\n");
			gigabyte->dual_fan_speed_enabled = 1;
		}
	}

	/*
	 * A read of 0 is a value, not a missing answer: BCPS reads 0 on a
	 * machine that has never enabled the custom charging mode, which is the
	 * factory state here. Testing the value rather than the return code
	 * meant the cache kept whatever it was initialised with.
	 *
	 * Mask bit 2 rather than shifting the whole nibble: BCPS is four bits
	 * wide, so a stray bit 3 would otherwise read back as mode 2 or 3 from
	 * a node that only accepts 0 and 1.
	 */
	/*
	 * Test implementation by reply type, not by return code. An
	 * unimplemented WMBC ID falls through to Default { Return (Arg2) } and
	 * the echoed buffer is copied out as a successful read of the argument,
	 * so `if (ret)` here never fires and the old "unsupported by this
	 * firmware" messages were unreachable.
	 *
	 * Both IDs are required together: a ceiling without the enable bit is
	 * inert, and the enable without a ceiling is meaningless.
	 */
	if (gigabyte_laptop_method_implemented(CHARGING_MODE) &&
		gigabyte_laptop_method_implemented(CHARGING_LIMIT) &&
		!gigabyte_laptop_get_devstate(CHARGING_MODE, &output)) {
		gigabyte->charge_mode = (output >> 2) & 1;

		if (!gigabyte_laptop_get_devstate(CHARGING_LIMIT, &output)) {
			gigabyte->charge_limit = output;
			gigabyte->has_charge_control = 1;
		}
	}

	if (!gigabyte->has_charge_control)
		pr_info("Charge control unsupported by this firmware\n");

	// Get the fan curve. Used by custom mode.
	for (u8 i = 0; i < FAN_CURVE_POINTS; i++) {
		ret = gigabyte_laptop_get_devstate2(FAN_INDEX_VALUE, i, &output);
		if (ret) {
			pr_info("Fan curve unreadable on this firmware\n");
			break;
		}
		else if (output) {
			gigabyte->fan_curve.temperature[i] = output;
			gigabyte->fan_curve.speed[i] = output >> 8;
		}
	}

	/*
	 * Test for the new light sensor method. Older models don't support it.
	 *
	 * The fallback used to be unconditional: anything that was not the new
	 * method installed the old one without checking it existed, so firmware
	 * carrying neither -- the Gaming generation -- ended up with 0xF7
	 * installed and a node that answered the echo forever.
	 */
	gigabyte->light_sensor_method = gigabyte_laptop_light_sensor_method();
	if (!gigabyte->light_sensor_method)
		pr_info("Light sensor unsupported by this firmware\n");
	else if (gigabyte->light_sensor_method == LIGHT_SENSOR_NEW)
		pr_info("Using new light sensor method\n");
	else
		pr_info("Using old light sensor method\n");

	// AORUS VG, Gaming (2025+) and all Aero X16 models can eject dGPU
	if (gigabyte_laptop_family_is("GIGABYTE AERO") ||
		gigabyte_laptop_family_is("GIGABYTE GAMING")) {
		gigabyte->has_dgpu_ejector = 1;
	}
	else if (gigabyte_laptop_family_is("AORUS") &&
		dmi_get_bios_year() >= 2024) {
		// Specifically check if we are on any of the AORUS VG models.
		// This filters out all VF models, as some have BIOS updates released
		// in 2024.
		if (dmi_check_system(gigabyte_laptop_dgpu_ejector_needed)) {
			gigabyte->has_dgpu_ejector = 1;
		}
		// AORUS 16X can eject dGPU
		else if (find_str(dmi_get_system_info(DMI_PRODUCT_NAME), "AORUS 16X") == 0) {
			gigabyte->has_dgpu_ejector = 1;
		}
		// Covers AORUS Elite/Master models
		else if (dmi_get_bios_year() >= 2025) {
			gigabyte->has_dgpu_ejector = 1;
		}
	}

	/*
	 * Read back the Gigabyte Gaming nodes.
	 *
	 * Performance mode is deliberately not read. The firmware implements
	 * 0xED under WMBD but has no WMBC case for it, so it is write-only and
	 * the mode in effect cannot be recovered. perf_mode therefore reports
	 * what was last written to it, starting at eco after a cold boot
	 * regardless of what the firmware is actually doing.
	 *
	 * Dynamic boost reads back NPCF.DBAC, which is already in the node's
	 * own sense: writing 0 sets DBAC to 1. The inversion belongs on the
	 * write path only.
	 *
	 * Turbo fan has no state of its own to read, being a combination of fan
	 * mode and duty rather than a single value.
	 */
	if (gigabyte->gaming_family) {
		if (!gigabyte_laptop_get_devstate(DYN_BOOST, &output))
			gigabyte->dynamic_boost = output;
		else
			pr_info("Dynamic boost unsupported by this firmware\n");
	}

	/*
	 * Keyboard backlight. Not inside the gaming_family guard: 0xF6 is not
	 * Gaming-only, so the gate is a runtime capability read rather than DMI.
	 *
	 * Seed the cached brightness from hardware before registration, so
	 * whichever way the LED core resolves an unset value at registration it
	 * cannot darken a lit keyboard at every module load.
	 */
	if (gigabyte_laptop_method_implemented(KBD_BRIGHTNESS) &&
		!gigabyte_laptop_get_devstate(KBD_BRIGHTNESS, &output)) {
		gigabyte->has_kbd_backlight = 1;
		gigabyte->kbd_led.brightness = clamp_val(output, 0, KBD_BRIGHTNESS_MAX);
	}
	else
		pr_info("Keyboard backlight unsupported by this firmware\n");

	return 0;
}

static struct platform_driver platform_driver = {
	.driver = {
		.name = GIGABYTE_LAPTOP_FILE,
		.owner = THIS_MODULE,
	},
};

static void __exit gigabyte_laptop_exit(void)
{
	struct gigabyte_laptop_wmi *gigabyte;

	pr_info("Stopping Gigabyte laptop WMI driver\n");

	// Stop the event sources before the input device they report into
	gigabyte_laptop_remove_acpi_notify();
	if (gigabyte_laptop_event_driver_live) {
		wmi_driver_unregister(&gigabyte_laptop_event_driver);
		gigabyte_laptop_event_driver_live = false;
	}
	gigabyte_laptop_input_destroy();

	gigabyte = platform_get_drvdata(platform_device);
	hwmon_device_unregister(gigabyte->hwmon_dev);
	sysfs_remove_group(&gigabyte->pdev->dev.kobj, &gigabyte_laptop_attr_group);
	platform_driver_unregister(&platform_driver);
	platform_device_unregister(gigabyte->pdev);
	platform_device = NULL;
	mutex_destroy(&gigabyte->charge_lock);
	mutex_destroy(&gigabyte->fan_lock);
	mutex_destroy(&gigabyte->power_lock);
	kfree(gigabyte);
}

static int __init gigabyte_laptop_init(void)
{
	struct gigabyte_laptop_wmi *gigabyte;
	int result;

	if (!wmi_has_guid(WMI_METHOD_WMBC) ||
		!wmi_has_guid(WMI_METHOD_WMBD)) {
		pr_warn("No known WMI GUID found!\n");
		return -ENODEV;
	}

	if (!dmi_check_system(gigabyte_laptop_known_working_platforms)) {
		pr_err("Laptop not supported\n");
		return -ENODEV;
	}

	result = platform_driver_register(&platform_driver);
	if (result) {
		pr_warn("Unable to register platform driver\n");
		return result;
	}

	gigabyte = kzalloc(sizeof(struct gigabyte_laptop_wmi), GFP_KERNEL);
	if (!gigabyte) {
		result = -ENOMEM;
		goto fail_platform_driver;
	}

	mutex_init(&gigabyte->fan_lock);
	mutex_init(&gigabyte->charge_lock);
	mutex_init(&gigabyte->power_lock);

	// Needed before the attribute group is created, as it gates what is shown
	gigabyte->gaming_family = gigabyte_laptop_is_gaming_family();

	// Needed before hwmon registration, as it gates which fans are exposed
	gigabyte_laptop_detect_fan_count(gigabyte);

	platform_device = platform_device_alloc(GIGABYTE_LAPTOP_FILE, -1);
	if (!platform_device) {
		pr_warn("Unable to allocate platform device\n");
		result = -ENOMEM;
		goto fail_alloc;
	}

	gigabyte->pdev = platform_device;
	platform_set_drvdata(gigabyte->pdev, gigabyte);

	result = platform_device_add(gigabyte->pdev);
	if (result) {
		pr_warn("Unable to add platform device\n");
		goto fail_platform_device;
	}

	result = sysfs_create_group(&gigabyte->pdev->dev.kobj,
					&gigabyte_laptop_attr_group);
	if (result)
		goto fail_sysfs;

	gigabyte->hwmon_dev = hwmon_device_register_with_info(&gigabyte->pdev->dev,
			GIGABYTE_LAPTOP_FILE, gigabyte, &gigabyte_laptop_chip_info, NULL);
	if (IS_ERR(gigabyte->hwmon_dev)) {
		result = PTR_ERR(gigabyte->hwmon_dev);
		pr_err("hwmon registration failed with %d\n", result);
		goto fail_hwmon;
	}

	result = gigabyte_laptop_probe(&gigabyte->pdev->dev);
	if (result) {
		pr_err("Probe failed\n");
		goto fail_probe;
	}

	/*
	 * Registered after probe, so the fan mode it syncs from has been read.
	 *
	 * devm is correct here and the non-devm API would be a regression, so
	 * resist "fix" suggestions to swap it. The class device is tied to
	 * `gigabyte->pdev->dev`, and gigabyte_laptop_exit() calls
	 * platform_device_unregister() on exactly that device, which releases
	 * devres — and it does so *before* kfree(gigabyte), so profile_get and
	 * profile_set cannot run against freed drvdata. Calling
	 * platform_profile_remove() as well would be a second teardown of the
	 * same registration.
	 */
	gigabyte->ppdev = devm_platform_profile_register(&gigabyte->pdev->dev,
			GIGABYTE_LAPTOP_FILE, gigabyte, &gigabyte_laptop_profile_ops);
	if (IS_ERR(gigabyte->ppdev)) {
		pr_warn("Could not register platform profile (%ld)\n",
			PTR_ERR(gigabyte->ppdev));
		gigabyte->ppdev = NULL;
	}

	/*
	 * Keyboard backlight, after probe so has_kbd_backlight is set and the
	 * cached brightness has been seeded from hardware. devm for the same
	 * reason as the platform profile above: the class device hangs off the
	 * platform device that exit unregisters, which releases devres -- and
	 * does so before kfree(gigabyte), so the core's flush of any pending
	 * deferred write still finds live driver state.
	 *
	 * LED_BRIGHT_HW_CHANGED is honest here only because the EC really does
	 * publish Fn+Space as a 0xF6 event; see the notifier. Deliberately no
	 * LED_CORE_SUSPENDRESUME, which would write 0 at suspend -- with
	 * brightness_get implemented a post-resume read is truthful anyway.
	 */
	if (gigabyte->has_kbd_backlight) {
		gigabyte->kbd_led.name = GIGABYTE_LAPTOP_FILE "::kbd_backlight";
		gigabyte->kbd_led.max_brightness = KBD_BRIGHTNESS_MAX;
		gigabyte->kbd_led.brightness_set_blocking =
			gigabyte_laptop_kbd_brightness_set;
		gigabyte->kbd_led.brightness_get =
			gigabyte_laptop_kbd_brightness_get;
		/*
		 * RETAIN_AT_SHUTDOWN because led_classdev_unregister() otherwise
		 * writes LED_OFF on the way out, and this registration is
		 * devm-managed -- so every rmmod, DKMS upgrade and package
		 * reinstall would turn a lit keyboard off. Probe deliberately seeds
		 * the brightness from hardware so that *loading* the module leaves
		 * a lit keyboard alone; without this flag the unload path undid
		 * exactly that.
		 */
		gigabyte->kbd_led.flags = LED_BRIGHT_HW_CHANGED |
					LED_RETAIN_AT_SHUTDOWN;

		result = devm_led_classdev_register(&gigabyte->pdev->dev,
						&gigabyte->kbd_led);
		if (result) {
			pr_warn("Could not register the keyboard backlight (%d)\n",
				result);
			/*
			 * Clear it, or a later 0xF6 event would call
			 * led_classdev_notify_brightness_hw_changed() on a
			 * class device that was never registered and so has no
			 * brightness_hw_changed node for it to poke.
			 */
			gigabyte->has_kbd_backlight = 0;
		}
	}

	/*
	 * charge_control_end_threshold on the battery, after probe so the
	 * cached pair the getter serves has been read from firmware.
	 *
	 * The hook can fire immediately, and add_battery runs with the cache
	 * already valid because of that ordering. devm ties the unregistration
	 * to the platform device, which exit unregisters before kfree, so the
	 * extension is gone before the state its callbacks read.
	 */
	if (gigabyte->has_charge_control) {
		gigabyte->battery_hook.name = GIGABYTE_LAPTOP_FILE "-charge-control";
		gigabyte->battery_hook.add_battery = gigabyte_laptop_add_battery;
		gigabyte->battery_hook.remove_battery = gigabyte_laptop_remove_battery;

		result = devm_battery_hook_register(&gigabyte->pdev->dev,
						&gigabyte->battery_hook);
		if (result)
			pr_warn("Could not register the charge threshold (%d)\n",
				result);
	}

	/*
	 * Hotkeys are a bonus on top of the sensors and controls, so none of
	 * this is worth failing the whole driver over. The input device goes
	 * first, since the event handler reports into it.
	 */
	result = gigabyte_laptop_input_setup(&gigabyte->pdev->dev);
	if (result)
		pr_warn("Could not create the hotkey input device (%d)\n", result);

	result = wmi_driver_register(&gigabyte_laptop_event_driver);
	if (result)
		pr_warn("Could not register WMI event driver (%d)\n", result);
	else
		gigabyte_laptop_event_driver_live = true;

	gigabyte_laptop_install_acpi_notify();
	result = 0;

	pr_info("Gigabyte laptop WMI driver started\n");
	return 0;

fail_probe:
	hwmon_device_unregister(gigabyte->hwmon_dev);
fail_hwmon:
	sysfs_remove_group(&gigabyte->pdev->dev.kobj, &gigabyte_laptop_attr_group);
fail_sysfs:
	platform_device_del(gigabyte->pdev);
fail_platform_device:
	platform_device_put(gigabyte->pdev);
	// is_visible() reads this global, so leave nothing dangling behind it
	platform_device = NULL;
fail_alloc:
	mutex_destroy(&gigabyte->charge_lock);
	mutex_destroy(&gigabyte->fan_lock);
	mutex_destroy(&gigabyte->power_lock);
	kfree(gigabyte);
fail_platform_driver:
	platform_driver_unregister(&platform_driver);
	return result;
}

module_init(gigabyte_laptop_init);
module_exit(gigabyte_laptop_exit);
