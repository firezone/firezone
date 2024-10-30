Name: firezone-client-gui
Version: 1.0
Release: 1%{?dist}
Summary: The GUI Client for Firezone

URL: https://firezone.dev
License: Apache-2.0
Requires: systemd-resolved

%description

%prep

%build

%install
mkdir -p \
"%{buildroot}/usr/bin" \
"%{buildroot}/usr/lib/dev.firezone.client/unused"

BINS="%{_topdir}/../../target/release"

cp "$BINS/firezone-client-ipc" "%{buildroot}/usr/bin/"
cp "$BINS/firezone-client-gui" "%{buildroot}/usr/lib/dev.firezone.client/"
cp "%{_topdir}/../src-tauri/rpm_files/gui-shim.sh" "%{buildroot}/usr/bin/firezone-client-gui"

LIBS="/lib/$(uname -m)-linux-gnu"

cp \
"$LIBS/ld-linux-aarch64.so.1" \
"$LIBS/libc.so.6" \
"%{buildroot}/usr/lib/dev.firezone.client/unused"

cp \
"$LIBS/libappindicator3.so.1" \
"$LIBS/libayatana-appindicator3.so.1" \
"$LIBS/libayatana-ido3-0.4.so.0" \
"$LIBS/libayatana-indicator3.so.7" \
"$LIBS/libdbus-1.so.3" \
"$LIBS/libdbusmenu-glib.so.4" \
"$LIBS/libdbusmenu-gtk3.so.4" \
"$LIBS/libgdk-3.so.0" \
"$LIBS/libgio-2.0.so.0" \
"$LIBS/libglib-2.0.so.0" \
"$LIBS/libgmodule-2.0.so.0" \
"$LIBS/libgtk-3.so.0" \
"$LIBS/libicudata.so.70" \
"$LIBS/libicui18n.so.70" \
"$LIBS/libicuuc.so.70" \
"$LIBS/libjavascriptcoregtk-4.1.so.0" \
"$LIBS/libjpeg.so.8" \
"$LIBS/libm.so.6" \
"$LIBS/libmanette-0.2.so.0" \
"$LIBS/libpcre.so.3" \
"$LIBS/libpcre2-8.so.0" \
"$LIBS/libsoup-3.0.so.0" \
"$LIBS/libstdc++.so.6" \
"$LIBS/libwayland-client.so.0" \
"$LIBS/libwayland-server.so.0" \
"$LIBS/libwebkit2gtk-4.1.so.0" \
"$LIBS/libxcb.so.1" \
"$LIBS/libxcb-shm.so.0" \
"$LIBS/libX11.so.6" \
"$LIBS/libX11-xcb.so.1" \
"%{buildroot}/usr/lib/dev.firezone.client/"

WEBKIT_DIR="usr/lib/$(uname -m)-linux-gnu/webkit2gtk-4.1"
mkdir -p "%{buildroot}/$WEBKIT_DIR"

cp \
"/$WEBKIT_DIR/WebKitNetworkProcess" \
"/$WEBKIT_DIR/WebKitWebProcess" \
"%{buildroot}/$WEBKIT_DIR"

mkdir -p "%{buildroot}/usr/lib/systemd/system"
cp "%{_topdir}/../src-tauri/deb_files/firezone-client-ipc.service" "%{buildroot}/usr/lib/systemd/system/firezone-client-ipc.service"

mkdir -p "%{buildroot}/usr/lib/sysusers.d"
cp "%{_topdir}/../src-tauri/deb_files/sysusers.conf" "%{buildroot}/usr/lib/sysusers.d/firezone-client-ipc.conf"

%files
/usr/bin/firezone-client-ipc
/usr/bin/firezone-client-gui
/usr/lib/dev.firezone.client/firezone-client-gui

# DNF expects libc and ld-linux to be packaged, because it checks the exes with ldd or something, but if we actually use them, the GUI process will segfault. So just dump them somewhere unused.
/usr/lib/dev.firezone.client/unused/ld-linux-aarch64.so.1
/usr/lib/dev.firezone.client/unused/libc.so.6

/usr/lib/dev.firezone.client/libappindicator3.so.1
/usr/lib/dev.firezone.client/libayatana-appindicator3.so.1
/usr/lib/dev.firezone.client/libayatana-ido3-0.4.so.0
/usr/lib/dev.firezone.client/libayatana-indicator3.so.7
/usr/lib/dev.firezone.client/libdbus-1.so.3
/usr/lib/dev.firezone.client/libdbusmenu-glib.so.4
/usr/lib/dev.firezone.client/libdbusmenu-gtk3.so.4
/usr/lib/dev.firezone.client/libgdk-3.so.0
/usr/lib/dev.firezone.client/libgio-2.0.so.0
/usr/lib/dev.firezone.client/libglib-2.0.so.0
/usr/lib/dev.firezone.client/libgmodule-2.0.so.0
/usr/lib/dev.firezone.client/libgtk-3.so.0
/usr/lib/dev.firezone.client/libicudata.so.70
/usr/lib/dev.firezone.client/libicui18n.so.70
/usr/lib/dev.firezone.client/libicuuc.so.70
/usr/lib/dev.firezone.client/libjavascriptcoregtk-4.1.so.0
/usr/lib/dev.firezone.client/libjpeg.so.8
/usr/lib/dev.firezone.client/libm.so.6
/usr/lib/dev.firezone.client/libmanette-0.2.so.0
/usr/lib/dev.firezone.client/libpcre.so.3
/usr/lib/dev.firezone.client/libpcre2-8.so.0
/usr/lib/dev.firezone.client/libsoup-3.0.so.0
/usr/lib/dev.firezone.client/libstdc++.so.6
/usr/lib/dev.firezone.client/libwayland-client.so.0
/usr/lib/dev.firezone.client/libwayland-server.so.0
/usr/lib/dev.firezone.client/libwebkit2gtk-4.1.so.0
/usr/lib/dev.firezone.client/libxcb.so.1
/usr/lib/dev.firezone.client/libxcb-shm.so.0
/usr/lib/dev.firezone.client/libX11.so.6
/usr/lib/dev.firezone.client/libX11-xcb.so.1

/usr/lib/systemd/system/firezone-client-ipc.service
/usr/lib/sysusers.d/firezone-client-ipc.conf

%ifarch aarch64
/usr/lib/aarch64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess
/usr/lib/aarch64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess
%endif

%ifarch x86_64
/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess
/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess
%endif

%post
%{?systemd_post firezone-client-ipc.service}

%preun
%{?systemd_preun firezone-client-ipc.service}

%postun
%{?systemd_postun_with_restart firezone-client-ipc.service}
