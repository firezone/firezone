Name: firezone-client-gui
Version: 1.0
Release: 1%{?dist}
Summary: The GUI Client for Firezone

URL: https://firezone.dev
License: Apache-2.0

%description

%prep

%build

%install
mkdir -p \
"%{buildroot}/usr/bin" \
"%{buildroot}/usr/lib/dev.firezone.client"

BINS="%{_topdir}/../../target/release"

cp \
"$BINS/firezone-client-ipc" \
"$BINS/firezone-client-gui" \
"%{buildroot}/usr/bin/"

LIBS="/lib/$(uname -m)-linux-gnu"

cp \
"$LIBS/libjavascriptcoregtk-4.1.so.0" \
"$LIBS/libwebkit2gtk-4.1.so.0" \
"%{buildroot}/usr/lib/dev.firezone.client/"

%files
/usr/bin/firezone-client-ipc
/usr/bin/firezone-client-gui
/usr/lib/dev.firezone.client/libjavascriptcoregtk-4.1.so.0
/usr/lib/dev.firezone.client/libwebkit2gtk-4.1.so.0
