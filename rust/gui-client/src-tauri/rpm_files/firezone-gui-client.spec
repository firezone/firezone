Name: firezone-client-gui
Version: 1.0
Release: 1%{?dist}
Summary: The GUI Client for Firezone

URL: https://firezone.dev
License: Apache-2.0
Requires: libwebkit2gtk-4.1

%description

%prep

%build

%install
mkdir -p %{buildroot}/usr/bin

cp /root/rpmbuild/bins/firezone-client-ipc %{buildroot}/usr/bin/
cp /root/rpmbuild/bins/firezone-gui-client %{buildroot}/usr/bin/

%files
/usr/bin/firezone-client-ipc
/usr/bin/firezone-gui-client
