// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * gigabyte-fan-preset-notify - put a desktop notification on screen when the
 * Mode key changes the fan preset.
 *
 * The driver calls sysfs_notify() on fan_preset when the key is pressed, which
 * is what poll() waits on here. It does *not* notify on a sysfs write, so this
 * reacts to the key and nothing else -- which is the point: a write already has
 * a caller who knows the outcome.
 *
 * The driver also emits a uevent for the same change, but a udev rule runs as
 * root in systemd-udevd, outside the session, with no bus to post a
 * notification on. That is why this is a session-side watcher rather than a
 * rule.
 *
 * Runs as the user, needs no privileges, and allocates nothing.
 */

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define ATTR "/sys/devices/platform/gigabyte_laptop/fan_preset"

/*
 * poll() must not wait forever. A module reload orphans the kernfs node behind
 * an open fd: no event is ever delivered again, so an infinite wait never
 * returns and the loss below is never noticed. Waking periodically is what
 * turns that silent deafness into something detectable. The interval only
 * bounds how long toasts stay missing after a reinstall, so seconds are fine.
 */
#define POLL_INTERVAL_MS 5000

/*
 * The notification text comes from this table and never from the file. A value
 * read out of sysfs is only ever used to pick an index, so no kernel-supplied
 * string reaches execlp() -- there is nothing to quote, escape or truncate.
 */
static const struct {
	const char *value;
	const char *text;
} presets[] = {
	{ "auto",   "Fan preset: auto — the power profile decides" },
	{ "silent", "Fan preset: silent" },
	{ "normal", "Fan preset: normal" },
	{ "gaming", "Fan preset: gaming" },
};

static int lookup(const char *value)
{
	for (size_t i = 0; i < sizeof(presets) / sizeof(presets[0]); i++)
		if (!strcmp(value, presets[i].value))
			return (int)i;

	return -1;
}

/* Re-read from the top. sysfs hands back the whole value on each read. */
static int read_preset(int fd, char *buf, size_t size)
{
	ssize_t len;

	if (lseek(fd, 0, SEEK_SET) == (off_t)-1)
		return -1;

	len = read(fd, buf, size - 1);
	if (len <= 0)
		return -1;

	buf[len] = '\0';
	buf[strcspn(buf, "\n")] = '\0';
	return 0;
}

/*
 * Open the attribute and consume its event counter, which is what makes a
 * subsequent poll() block instead of returning immediately. Shared by startup
 * and by recovery after a module reload, because both need the same arming
 * read and getting it wrong spins at 100% CPU.
 */
static int arm(int *fd, char *buf, size_t size)
{
	int new_fd = open(ATTR, O_RDONLY);

	if (new_fd < 0)
		return -1;

	if (read_preset(new_fd, buf, size)) {
		close(new_fd);
		return -1;
	}

	if (*fd >= 0)
		close(*fd);
	*fd = new_fd;
	return 0;
}

static void notify(const char *text)
{
	pid_t pid = fork();

	if (pid < 0) {
		perror("fork");
		return;
	}

	if (pid == 0) {
		execlp("notify-send", "notify-send",
			"--app-name=Gigabyte laptop",
			"--icon=computer",
			"--expire-time=2000",
			text, (char *)NULL);
		/* Only reached if notify-send is missing. */
		perror("notify-send");
		_exit(127);
	}
}

int main(void)
{
	struct pollfd pfd;
	char buf[32];
	int fd, idx;

	/* A notification's exit status is of no interest, so reap by ignoring. */
	signal(SIGCHLD, SIG_IGN);

	/*
	 * The arming read is not optional: until the attribute's event counter
	 * has been consumed, poll() returns immediately and would spin at 100%
	 * CPU. What it returns is current state rather than a change, so it is
	 * recorded and not announced.
	 *
	 * Failing here is fatal, unlike a loss mid-life. The .path unit starts
	 * this only once the attribute exists, so an attribute that cannot be
	 * opened at startup means something is wrong rather than in flux.
	 */
	fd = -1;
	if (arm(&fd, buf, sizeof(buf))) {
		perror(ATTR);
		return 1;
	}
	idx = lookup(buf);

	pfd.fd = fd;
	pfd.events = POLLPRI | POLLERR;

	for (;;) {
		int ret = poll(&pfd, 1, POLL_INTERVAL_MS);

		if (ret < 0) {
			perror("poll");
			return 1;
		}

		/*
		 * Nothing happened, so this is the liveness check rather than an
		 * event. A read is the probe because it is the only thing that
		 * distinguishes a live node from an orphaned one: kernfs fails a
		 * read on a removed node, while the fd, the path and poll() all
		 * keep looking healthy. Recovering means re-opening -- the new
		 * node is a different inode, so the old fd can never be revived.
		 *
		 * Re-opening here rather than exiting is deliberate. Exiting
		 * would hand recovery to the .path unit, which cannot do it: a
		 * Wants= or PathExists= trigger enqueues a *start*, and a start
		 * against a still-active unit is a no-op, so the reload window
		 * is lost before this process ever notices. Self-healing needs
		 * no second activation path and no udev rule.
		 */
		if (ret == 0) {
			if (!read_preset(fd, buf, sizeof(buf)))
				continue;

			if (arm(&fd, buf, sizeof(buf)))
				continue;

			pfd.fd = fd;
			idx = lookup(buf);
			fprintf(stderr, "%s: re-opened after a driver reload\n",
				ATTR);
			continue;
		}

		/*
		 * POLLERR accompanies every POLLPRI on a sysfs attribute, so it
		 * is not an error on its own. A failed read here means the node
		 * went away between the wake and the read, which the next
		 * liveness check will recover from.
		 */
		if (read_preset(fd, buf, sizeof(buf)))
			continue;

		idx = lookup(buf);
		if (idx < 0) {
			fprintf(stderr, "unrecognised fan preset, ignoring\n");
			continue;
		}

		/*
		 * Announce every wake, without comparing against the previous
		 * value. The driver notifies only from the key path and the key
		 * always moves the preset, so a wake *is* a change and a
		 * duplicate toast cannot happen -- while suppressing on equality
		 * loses a real one: four fast presses go round the whole ring
		 * back to the starting preset, and this would then report
		 * nothing at all.
		 *
		 * What remains, and is inherent to sysfs_notify() rather than to
		 * this comparison: presses faster than one wake collapse into a
		 * single toast showing the final preset, because the attribute
		 * carries a value and not a queue. Fixing that properly means
		 * consuming the driver's uevent stream instead, which costs a
		 * libudev dependency and a great deal more code to recover
		 * intermediate states nobody saw on the keyboard either.
		 */
		notify(presets[idx].text);
	}
}
