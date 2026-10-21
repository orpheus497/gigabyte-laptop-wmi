Name:       gigabyte-laptop-kmod-common

Version:        0.2.0
# Release 2: the rename, and the bump the Obsoletes below needs to match.
Release:        2%{?dist}
Summary:        Common file for gigabyte-laptop drivers
License:        GPL
URL:            https://github.com/tangalbert919/gigabyte-laptop-wmi

Source0:        gigabyte-laptop.conf

Requires:       gigabyte-laptop-kmod = %{?epoch:%{epoch}:}%{version}
Provides:       gigabyte-laptop-kmod-common = %{?epoch:%{epoch}:}%{version}

# Replaces the pre-rename package, whose only payload was the equivalent
# /etc/modules-load.d/aorus-laptop.conf. Obsoleting it is what gets that stale
# entry removed; leaving it behind would try to load a module that is gone.
#
# Release is 2 for the same reason as in the DKMS spec: the last
# aorus-laptop-kmod-common was 0.2.0-1, so a bound built from Release 1 would
# not have matched it.
Obsoletes:      aorus-laptop-kmod-common < %{version}-%{release}

%description
Common package for gigabyte-laptop drivers. Mostly empty.

%install
install -p -m 0644 -D %{SOURCE0} %{buildroot}%{_sysconfdir}/modules-load.d/gigabyte-laptop.conf

%files
%{_sysconfdir}/modules-load.d/gigabyte-laptop.conf

%changelog
* Thu Oct 22 2026 Albert Tang <tangalbert919@yahoo.com> - 0.2.0-2
- Rename the driver from aorus-laptop to gigabyte-laptop
