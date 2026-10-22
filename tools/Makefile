# Userspace helper. Separate from the top-level kbuild Makefile on purpose:
# this is an ordinary host binary, not a kernel module.

CFLAGS ?= -O2 -Wall -Wextra -Wpedantic -std=gnu11
PREFIX ?= /usr/local
BIN     = gigabyte-fan-preset-notify

all: $(BIN)

$(BIN): $(BIN).c
	$(CC) $(CFLAGS) -o $@ $<

# A user unit, not a system one: it has to reach the session bus to post a
# notification. /usr/local/lib/systemd/user is in systemd's user unit path.
install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/$(BIN)
	install -Dm644 $(BIN).service \
		$(DESTDIR)$(PREFIX)/lib/systemd/user/$(BIN).service

clean:
	rm -f $(BIN)

.PHONY: all install clean
