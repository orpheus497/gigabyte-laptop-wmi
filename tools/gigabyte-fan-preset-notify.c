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
 * A module reload orphans the kernfs node behind an open fd, and it does so in
 * two different ways depending on where poll() happens to be:
 *
 *   - already inside poll() when the node is removed -- it sleeps on a wait
 *     queue that removal never wakes, so it waits for ever and the loss is
 *     never noticed. Measured: the watcher stayed blocked at zero CPU with the
 *     service reading active, missing every keypress.
 *   - entering poll() after removal -- it cannot take an active reference, so
 *     it returns POLLERR *immediately* instead of blocking.
 *
 * So both halves below are load-bearing. The timeout is what escapes the first
 * case, and handling a failed read on an ordinary (ret > 0) wake is what
 * handles the second. Getting only the first right converts a silent hang into
 * a busy loop, which is exactly what happened.
 */
#define POLL_INTERVAL_MS 5000

/*
 * How long to keep trying to re-open before giving up and letting the service
 * manager decide. Long enough to cover a DKMS reinstall, and the handover is
 * sound because by then the attribute is genuinely absent: the unit stops, so
 * the .path unit's later start is a real start rather than the no-op it is
 * against a still-active unit.
 */
#define RETRY_INTERVAL_S 2
#define RETRY_LIMIT      30

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
		 * POLLERR accompanies every POLLPRI on a live sysfs attribute,
		 * so it is not an error on its own and the poll result cannot be
		 * used to tell a healthy node from a removed one. A failed read
		 * can: kernfs refuses a read once the node is gone, while the
		 * fd, the path, poll() and the unit state all still look fine.
		 *
		 * This has to be tested on every wake, timeout or not. A removed
		 * node makes poll() return POLLERR without blocking, so the loss
		 * arrives as ret > 0, and anything that loops without recovering
		 * from it spins a core flat.
		 */
		if (read_preset(fd, buf, sizeof(buf))) {
			int tries;

			/*
			 * Re-open rather than exit, because no unit dependency
			 * can do this for us: PathExists= and a udev
			 * SYSTEMD_USER_WANTS= both enqueue a start, and a start
			 * against a still-active unit is a no-op. The measured
			 * reload window was two seconds, so a trigger would
			 * have fired and been swallowed long before now.
			 */
			for (tries = 0; tries < RETRY_LIMIT; tries++) {
				if (!arm(&fd, buf, sizeof(buf)))
					break;
				/*
				 * Mandatory, not polite: the dead fd makes
				 * poll() return instantly, so a retry without
				 * this is the busy loop described above.
				 */
				sleep(RETRY_INTERVAL_S);
			}

			if (tries == RETRY_LIMIT) {
				fprintf(stderr, "%s: gone, exiting\n", ATTR);
				return 1;
			}

			pfd.fd = fd;
			idx = lookup(buf);
			fprintf(stderr, "%s: re-opened after a driver reload\n",
				ATTR);
			continue;
		}

		/* A healthy node and no event: the wake was our own timeout. */
		if (ret == 0)
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
