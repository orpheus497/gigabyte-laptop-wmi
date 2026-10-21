Name:       gigabyte-laptop-kmod-common

Version:        0.2.0
Release:        1%{?dist}
Summary:        Common file for gigabyte-laptop drivers
License:        GPL
URL:            https://github.com/tangalbert919/gigabyte-laptop-wmi

Source0:        gigabyte-laptop.conf

Requires:       gigabyte-laptop-kmod = %{?epoch:%{epoch}:}%{version}
Provides:       gigabyte-laptop-kmod-common = %{?epoch:%{epoch}:}%{version}

# Replaces the pre-rename package, whose only payload was the equivalent
# /etc/modules-load.d/aorus-laptop.conf. Obsoleting it is what gets that stale
# entry removed; leaving it behind would try to load a module that is gone.
Obsoletes:      aorus-laptop-kmod-common < %{version}-%{release}

%description
Common package for gigabyte-laptop drivers. Mostly empty.

%install
install -p -m 0644 -D %{SOURCE0} %{buildroot}%{_sysconfdir}/modules-load.d/gigabyte-laptop.conf

%files
%{_sysconfdir}/modules-load.d/gigabyte-laptop.conf

%changelog
