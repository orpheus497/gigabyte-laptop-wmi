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
#
# It depends on the stamp as well, because Make cannot see a variable change:
# `make PREFIX=/usr/local && make PREFIX=/usr install` would otherwise think
# the unit up to date and install one pointing at the wrong prefix.
$(BIN).service: $(BIN).service.in .bindir.stamp
	sed -e 's|@BINDIR@|$(BINDIR)|g' $< > $@

# Rewritten only when BINDIR actually differs, so this is not a rebuild on
# every run.
.bindir.stamp: FORCE
	@printf '%s\n' '$(BINDIR)' | cmp -s - $@ || printf '%s\n' '$(BINDIR)' > $@

# A user unit, not a system one: it has to reach the session bus to post a
# notification. $(PREFIX)/lib/systemd/user is in systemd's user unit path.
install: $(BIN) $(BIN).service
	install -Dm755 $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)
	install -Dm644 $(BIN).service $(DESTDIR)$(UNITDIR)/$(BIN).service
	install -Dm644 $(BIN).path    $(DESTDIR)$(UNITDIR)/$(BIN).path

clean:
	rm -f $(BIN) $(BIN).service .bindir.stamp

.PHONY: all install clean FORCE
FORCE:
