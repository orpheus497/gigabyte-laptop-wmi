%define module gigabyte-laptop

Name:           %{module}-dkms

Version:        0.2.0
# Release 2: the rename, and this package now ships the modules-load.d entry.
# The bump is also what lets the Obsoletes below match -- see the note there.
Release:        2%{?dist}
Summary:        DKMS package for Gigabyte laptop kernel module

License:        GPL
URL:            https://github.com/tangalbert919/gigabyte-laptop-wmi
# Needs a release whose tarball contains gigabyte-laptop.c. Releases published
# before the rename carry aorus-laptop.c and will not build. CI does not use
# this URL -- it builds the tarball from the checkout and passes --sources=.
Source0:        https://github.com/tangalbert919/gigabyte-laptop-wmi/releases/download/%{version}/driver.tar.gz
Source1:        gigabyte-laptop.conf
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch

Requires:       dkms, gcc, make

# The driver was called aorus-laptop until the rename. Both modules claim the
# same WMI devices and poke the same EC, so they must never be installed at
# once.
#
# The bound has to clear 0.2.0-1, which is what the last aorus-laptop-dkms
# carried -- the same version this package has. That is why Release is 2: at
# Release 1 the bound was 0.2.0-1 and excluded the very package it has to
# replace, leaving the old one installed alongside. There is deliberately no
# Conflicts: Obsoletes already stops the two coexisting, and a second
# relationship on the same name only adds ways for the transaction to fail.
Obsoletes:      aorus-laptop-dkms < %{version}-%{release}

%description
This package contains the DKMS gigabyte-laptop kernel module.

%prep
%setup -q -c -T -a 0
sed -e "s/@PKGVER@/%{version}/" -i %{_builddir}/%{name}-%{version}/dkms.conf

%install
if [ "$RPM_BUILD_ROOT" != "/" ]; then
    rm -rf $RPM_BUILD_ROOT
fi
mkdir -p $RPM_BUILD_ROOT/usr/src/
cp -rf ${RPM_BUILD_DIR}/%{name}-%{version} $RPM_BUILD_ROOT/usr/src/
mv $RPM_BUILD_ROOT/usr/src/%{name}-%{version} $RPM_BUILD_ROOT/usr/src/%{module}-%{version}
# No modalias on this module, so modules-load.d is the only thing that loads it
install -p -m 0644 -D %{SOURCE1} $RPM_BUILD_ROOT%{_sysconfdir}/modules-load.d/gigabyte-laptop.conf

%clean
rm -rf $RPM_BUILD_ROOT

%files
/usr/src/%{module}-%{version}
%{_sysconfdir}/modules-load.d/gigabyte-laptop.conf

%post
# Drop any other version this module is still registered under. %preun cannot:
# on an upgrade it belongs to the OLD package and runs after this scriptlet, so
# skipping it there (see below) would otherwise leave a stale DKMS tree behind
# whenever the version changes.
for v in $(dkms status -m gigabyte-laptop 2>/dev/null | sed -n "s|^gigabyte-laptop/\([^,:]*\).*|\1|p" | sort -u); do
    if [ "$v" != "%{version}" ]; then
        dkms remove -m gigabyte-laptop -v "$v" --all || :
    fi
done
# Tolerated: dkms add fails when the version is already registered, which is
# the normal case on a reinstall and not worth failing the scriptlet over.
dkms add -m gigabyte-laptop -v %{version} || :
dkms install --force -m gigabyte-laptop -v %{version}

%preun
# $1 is 0 only on a real erase; on an upgrade it is 1 and the new package's
# %post has already re-added the module, so removing it here would tear out
# what was just installed. Version changes are handled by that %post instead.
if [ $1 -eq 0 ]; then
    dkms remove -m gigabyte-laptop -v %{version} --all || :
fi

%changelog
* Thu Oct 22 2026 Albert Tang <tangalbert919@yahoo.com> - 0.2.0-2
- Rename the driver from aorus-laptop to gigabyte-laptop
- Ship the /etc/modules-load.d entry, which has no modalias to autoload it
