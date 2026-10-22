# Userspace helper. Separate from the top-level kbuild Makefile on purpose:
# this is an ordinary host binary, not a kernel module.

CFLAGS ?= -O2 -Wall -Wextra -Wpedantic -std=gnu11
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
UNITDIR ?= $(PREFIX)/lib/systemd/user
BIN      = gigabyte-fan-preset-notify

all: $(BIN) $(BIN).service

$(BIN): $(BIN).c
	$(CC) $(CFLAGS) -o $@ $<

# The unit is generated rather than shipped, so ExecStart always matches where
# the binary actually went. A fixed /usr/local/bin in a committed unit breaks
# any install with a different PREFIX, which is the one way to get a service
# that enables cleanly and then fails to start.
$(BIN).service: $(BIN).service.in
	sed -e 's|@BINDIR@|$(BINDIR)|g' $< > $@

# A user unit, not a system one: it has to reach the session bus to post a
# notification. $(PREFIX)/lib/systemd/user is in systemd's user unit path.
install: $(BIN) $(BIN).service
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)
	install -Dm644 $(BIN).service $(DESTDIR)$(UNITDIR)/$(BIN).service
	install -Dm644 $(BIN).path    $(DESTDIR)$(UNITDIR)/$(BIN).path

clean:
	rm -f $(BIN) $(BIN).service

.PHONY: all install clean
