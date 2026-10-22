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

	fd = open(ATTR, O_RDONLY);
	if (fd < 0) {
		perror(ATTR);
		return 1;
	}

	/*
	 * This first read is what arms the wait, and it is not optional:
	 * until the attribute's event counter has been consumed, poll()
	 * returns immediately and would spin at 100% CPU. The value it
	 * returns is the current state rather than a change, so it is
	 * recorded and not announced.
	 */
	if (read_preset(fd, buf, sizeof(buf))) {
		perror("read");
		return 1;
	}
	idx = lookup(buf);

	pfd.fd = fd;
	pfd.events = POLLPRI | POLLERR;

	for (;;) {
		int prev = idx;

		if (poll(&pfd, 1, -1) < 0) {
			perror("poll");
			return 1;
		}

		/*
		 * POLLERR accompanies every POLLPRI on a sysfs attribute, so it
		 * is not an error on its own. A failed read is: it means the
		 * driver went away, and the service manager should decide what
		 * happens next rather than this looping on a dead fd.
		 */
		if (read_preset(fd, buf, sizeof(buf))) {
			fprintf(stderr, "%s: gone, exiting\n", ATTR);
			return 1;
		}

		idx = lookup(buf);
		if (idx < 0) {
			fprintf(stderr, "unrecognised fan preset, ignoring\n");
			continue;
		}

		/* The same value can be re-notified; do not toast twice for it. */
		if (idx != prev)
			notify(presets[idx].text);
	}
}
