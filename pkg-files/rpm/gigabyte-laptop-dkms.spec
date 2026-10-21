%define module gigabyte-laptop

Name:           %{module}-dkms

Version:        0.2.0
Release:        1%{?dist}
Summary:        DKMS package for Gigabyte laptop kernel module

License:        GPL
URL:            https://github.com/tangalbert919/gigabyte-laptop-wmi
Source0:        https://github.com/tangalbert919/gigabyte-laptop-wmi/releases/download/%{version}/driver.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch

Requires:       dkms, gcc, make

%description
This package contains the DKMS gigabyte-laptop kernel module.

%prep
%setup -q -c -T -a 0
#install -m 0644 %{SOURCE1} %{builddir}/dkms.conf
sed -e "s/@PKGVER@/%{version}/" -i %{builddir}/%{name}-%{version}/dkms.conf

%install
if [ "$RPM_BUILD_ROOT" != "/" ]; then
    rm -rf $RPM_BUILD_ROOT
fi
mkdir -p $RPM_BUILD_ROOT/usr/src/
cp -rf ${RPM_BUILD_DIR}/%{name}-%{version} $RPM_BUILD_ROOT/usr/src/
mv $RPM_BUILD_ROOT/usr/src/%{name}-%{version} $RPM_BUILD_ROOT/usr/src/%{module}-%{version}

%clean
rm -rf $RPM_BUILD_ROOT

%files
/usr/src/%{module}-%{version}

%post
dkms add -m gigabyte-laptop -v %{version}
dkms install --force -m gigabyte-laptop -v %{version}

%preun
dkms remove -m gigabyte-laptop -v %{version} --all

%changelog
