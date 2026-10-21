%define module gigabyte-laptop

Name:           %{module}-dkms

Version:        0.2.0
Release:        1%{?dist}
Summary:        DKMS package for Gigabyte laptop kernel module

License:        GPL
URL:            https://github.com/tangalbert919/gigabyte-laptop-wmi
Source0:        https://github.com/tangalbert919/gigabyte-laptop-wmi/releases/download/%{version}/driver.tar.gz
Source1:        gigabyte-laptop.conf
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch

Requires:       dkms, gcc, make

# The driver was called aorus-laptop until the rename. Both modules claim the
# same WMI devices and poke the same EC, so they must never be installed at
# once.
Obsoletes:      aorus-laptop-dkms < %{version}-%{release}
Conflicts:      aorus-laptop-dkms

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
dkms add -m gigabyte-laptop -v %{version}
dkms install --force -m gigabyte-laptop -v %{version}

%preun
# $1 is 0 only on a real erase; on an upgrade it is 1 and the new package's
# %post re-adds the module, so removing it here would be churn at best and
# would leave nothing installed if the new %post failed.
if [ $1 -eq 0 ]; then
    dkms remove -m gigabyte-laptop -v %{version} --all
fi

%changelog
