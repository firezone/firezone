Name: firezone-client-gui
# mark:next-gui-version
Version: 1.4.14
Release: 1%{?dist}
Summary: The GUI Client for Firezone

URL: https://firezone.dev
License: Apache-2.0
Requires: systemd-resolved
BuildRequires: systemd-rpm-macros

# For some reason, the Ubuntu version of `rpmbuild` notices that we're providing our own WebKit and other libs, but the CentOS version doesn't. So we explicitly tell it not to worry about all these libs.
%global __requires_exclude ^(libdbus-1|libgdk-3|libgio-2.0|libglib-2.0|libgtk-3|libjavascriptcoregtk-4.1|libm|libsoup-3.0|libwebkit2gtk-4.1).so.*

%description

%prep

%build

%install
mkdir -p \
"%{buildroot}/usr/bin" \
"%{buildroot}/usr/lib/dev.firezone.client/unused"

BINS="%{_topdir}/../../target/release"

cp "$BINS/firezone-tunnel-service" "%{buildroot}/usr/bin/"
cp "$BINS/firezone-client-gui" "%{buildroot}/usr/lib/dev.firezone.client/"
cp "%{_topdir}/../src-tauri/rpm_files/gui-shim.sh" "%{buildroot}/usr/bin/firezone-client-gui"

LIBS="/root/libs/$(uname -m)-linux-gnu"

# DNF expects libc and ld-linux to be packaged, because it checks the exes with ldd or something, but if we actually use them, the GUI process will segfault. So just dump them somewhere unused.
UNUSED_DIR="%{buildroot}/usr/lib/dev.firezone.client/unused"

%ifarch aarch64
cp \
"$LIBS/ld-linux-aarch64.so.1" \
"$LIBS/libc.so.6" \
"$UNUSED_DIR"
%endif

%ifarch x86_64
cp \
"$LIBS/ld-linux-x86-64.so.2" \
"$LIBS/libc.so.6" \
"$UNUSED_DIR"
%endif

cp \
"$LIBS/libappindicator3.so.1" \
"$LIBS/libayatana-appindicator3.so.1" \
"$LIBS/libayatana-ido3-0.4.so.0" \
"$LIBS/libayatana-indicator3.so.7" \
"$LIBS/libdbus-1.so.3" \
"$LIBS/libdbusmenu-glib.so.4" \
"$LIBS/libdbusmenu-gtk3.so.4" \
"$LIBS/libfreetype.so.6" \
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

ls -lash "%{buildroot}/usr/lib/dev.firezone.client"

WEBKIT_DIR="$(uname -m)-linux-gnu/webkit2gtk-4.1"
mkdir -p "%{buildroot}/usr/lib/$WEBKIT_DIR"

cp \
"/root/libs/$WEBKIT_DIR/WebKitNetworkProcess" \
"/root/libs/$WEBKIT_DIR/WebKitWebProcess" \
"%{buildroot}/usr/lib/$WEBKIT_DIR"

ICONS="%{buildroot}/usr/share/icons/hicolor"

mkdir -p \
"%{buildroot}/usr/lib/systemd/system" \
"%{buildroot}/usr/lib/sysusers.d" \
"%{buildroot}/usr/share/applications" \
"$ICONS/32x32/apps" \
"$ICONS/128x128/apps" \
"$ICONS/512x512/apps"

cp \
"%{_topdir}/../src-tauri/deb_files/firezone-tunnel-service.service" \
"%{buildroot}/usr/lib/systemd/system/"

cp \
"%{_topdir}/../src-tauri/deb_files/sysusers.conf" \
"%{buildroot}/usr/lib/sysusers.d/firezone-tunnel-service.conf"

cp \
"%{_topdir}/../src-tauri/rpm_files/firezone-client-gui.desktop" \
"%{buildroot}/usr/share/applications/"

cp \
"%{_topdir}/../src-tauri/icons/32x32.png" \
"$ICONS/32x32/apps/firezone-client-gui.png"

cp \
"%{_topdir}/../src-tauri/icons/128x128.png" \
"$ICONS/128x128/apps/firezone-client-gui.png"

cp \
"%{_topdir}/../src-tauri/icons/icon.png" \
"$ICONS/512x512/apps/firezone-client-gui.png"

%files
/usr/bin/firezone-tunnel-service
/usr/bin/firezone-client-gui
/usr/lib/dev.firezone.client/firezone-client-gui

/usr/lib/dev.firezone.client/libappindicator3.so.1
/usr/lib/dev.firezone.client/libayatana-appindicator3.so.1
/usr/lib/dev.firezone.client/libayatana-ido3-0.4.so.0
/usr/lib/dev.firezone.client/libayatana-indicator3.so.7
/usr/lib/dev.firezone.client/libdbus-1.so.3
/usr/lib/dev.firezone.client/libdbusmenu-glib.so.4
/usr/lib/dev.firezone.client/libdbusmenu-gtk3.so.4
/usr/lib/dev.firezone.client/libfreetype.so.6
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

/usr/lib/systemd/system/firezone-tunnel-service.service
/usr/lib/sysusers.d/firezone-tunnel-service.conf

/usr/share/applications/firezone-client-gui.desktop
/usr/share/icons/hicolor/32x32/apps/firezone-client-gui.png
/usr/share/icons/hicolor/128x128/apps/firezone-client-gui.png
/usr/share/icons/hicolor/512x512/apps/firezone-client-gui.png

%ifarch aarch64
/usr/lib/aarch64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess
/usr/lib/aarch64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess

/usr/lib/dev.firezone.client/unused/ld-linux-aarch64.so.1
/usr/lib/dev.firezone.client/unused/libc.so.6
%endif

%ifarch x86_64
/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess
/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess

/usr/lib/dev.firezone.client/unused/ld-linux-x86-64.so.2
/usr/lib/dev.firezone.client/unused/libc.so.6
%endif

%post
%systemd_post firezone-tunnel-service.service

%preun
%systemd_preun firezone-tunnel-service.service

%postun
%systemd_postun_with_restart firezone-tunnel-service.service
