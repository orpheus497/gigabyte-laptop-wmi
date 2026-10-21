# (un)define the next line to either build for the newest or all current kernels
#define buildforkernels newest
#define buildforkernels current
#define buildforkernels akmod

%if 0%{?fedora}
%global buildforkernels akmod
%endif

%global debug_package %{nil}

# name should have a -kmod suffix
Name:           gigabyte-laptop-kmod

Version:        0.2.0
Release:        2%{?dist}
Summary:        Akmod package for Gigabyte laptop kernel module

License:        GPL
URL:            https://github.com/tangalbert919/gigabyte-laptop-wmi
Source0:        driver.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)


# Verify that the package build for all architectures.
# In most time you should remove the Exclusive/ExcludeArch directives
# and fix the code (if needed).
ExclusiveArch:  x86_64

# get the proper build-sysbuild package from the repo, which
# tracks in all the kernel-devel packages
BuildRequires:  %{_bindir}/kmodtool

%{!?kernels:BuildRequires: buildsys-build-rpmfusion-kerneldevpkgs-%{?buildforkernels:%{buildforkernels}}%{!?buildforkernels:current}-%{_target_cpu} }

# kmodtool does its magic here.
#
# The driver was renamed from aorus-laptop, but kmodtool generates the kmod and
# akmod subpackages itself and gives no hook for adding Obsoletes to them, so
# akmod-gigabyte-laptop cannot declare that it replaces akmod-aorus-laptop.
# Only gigabyte-laptop-kmod-common obsoletes its predecessor. Anyone upgrading
# from the old name has to remove the old akmod by hand:
#   sudo dnf remove akmod-aorus-laptop aorus-laptop-kmod-common
%{expand:%(kmodtool --target %{_target_cpu} --repo rpmfusion --kmodname %{name} %{?buildforkernels:--%{buildforkernels}} %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null) }

%description
Kmod package for Gigabyte laptop kernel module

%prep
# error out if there was something wrong with kmodtool
%{?kmodtool_check}

# print kmodtool output for debugging purposes:
kmodtool  --target %{_target_cpu}  --repo rpmfusion --kmodname %{name} %{?buildforkernels:--%{buildforkernels}} %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null

%setup -q -c -T -a 0

# apply patches and do other stuff here
# pushd foo-%{version}
# #patch0 -p1 -b .suffix
# popd
mkdir %{name}-%{version}
mv gigabyte-laptop.c %{name}-%{version}
mv Makefile %{name}-%{version}

for kernel_version in %{?kernel_versions} ; do
    cp -a %{name}-%{version} _kmod_build_${kernel_version%%___*}
done


%build
for kernel_version in %{?kernel_versions}; do
    make %{?_smp_mflags} -C "${kernel_version##*___}" SUBDIRS=${PWD}/_kmod_build_${kernel_version%%___*} M=${PWD}/_kmod_build_${kernel_version%%___*} modules
done


%install
rm -rf ${RPM_BUILD_ROOT}

for kernel_version in %{?kernel_versions}; do
    # make install DESTDIR=${RPM_BUILD_ROOT} KMODPATH=%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}
    mkdir -p  $RPM_BUILD_ROOT/%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/
    install -D -m 755 _kmod_build_${kernel_version%%___*}/gigabyte-laptop.ko  ${RPM_BUILD_ROOT}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/gigabyte-laptop.ko
done
%{?akmod_install}


%clean
rm -rf $RPM_BUILD_ROOT


%changelog
* Tue Oct 21 2025 Albert Tang <tangalbert919@yahoo.com> - 0.2.0-2
- Rename the driver from aorus-laptop to gigabyte-laptop

* Fri Nov 1 2024 Albert Tang <tangalbert919@yahoo.com> - 0.1.0
- Initial release for RPM-based Linux distros
