import { NextResponse, NextRequest } from "next/server";

// This middleware is needed because NextJS doesn't populate params in the destination
// more than once. See https://github.com/vercel/next.js/issues/66891
const versionedRedirects = [
  {
    source: /^\/dl\/firezone-client-android\/(\d+\.\d+\.\d+)\/apk/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/android-client-:version/firezone-android-client-:version.apk",
  },
  {
    source: /^\/dl\/firezone-client-android\/(\d+\.\d+\.\d+)\/aab/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/android-client-:version/firezone-android-client-:version.aab",
  },
  {
    source: /^\/dl\/firezone-client-gui-windows\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gui-client-:version/firezone-client-gui-windows_:version_x86_64.msi",
  },
  {
    source: /^\/dl\/firezone-client-gui-linux\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gui-client-:version/firezone-client-gui-linux_:version_x86_64.deb",
  },
  {
    source: /^\/dl\/firezone-client-gui-linux\/(\d+\.\d+\.\d+)\/aarch64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gui-client-:version/firezone-client-gui-linux_:version_aarch64.deb",
  },
  {
    source: /^\/dl\/firezone-client-headless-linux\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/headless-client-:version/firezone-client-headless-linux_:version_x86_64",
  },
  {
    source: /^\/dl\/firezone-client-headless-linux\/(\d+\.\d+\.\d+)\/aarch64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/headless-client-:version/firezone-client-headless-linux_:version_aarch64",
  },
  {
    source: /^\/dl\/firezone-client-headless-linux\/(\d+\.\d+\.\d+)\/armv7$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/headless-client-:version/firezone-client-headless-linux_:version_armv7",
  },
  {
    source: /^\/dl\/firezone-gateway\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gateway-:version/firezone-gateway_:version_x86_64",
  },
  {
    source: /^\/dl\/firezone-gateway\/(\d+\.\d+\.\d+)\/aarch64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gateway-:version/firezone-gateway_:version_aarch64",
  },
  {
    source: /^\/dl\/firezone-gateway\/(\d+\.\d+\.\d+)\/armv7$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gateway-:version/firezone-gateway_:version_armv7",
  },
];

export const config = {
  matcher: [
    "/dl/firezone-client-gui-windows/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-client-gui-linux/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-client-gui-linux/(\\d+).(\\d+).(\\d+)/aarch64",
    "/dl/firezone-client-headless-linux/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-client-headless-linux/(\\d+).(\\d+).(\\d+)/aarch64",
    "/dl/firezone-client-headless-linux/(\\d+).(\\d+).(\\d+)/armv7",
    "/dl/firezone-gateway/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-gateway/(\\d+).(\\d+).(\\d+)/aarch64",
    "/dl/firezone-gateway/(\\d+).(\\d+).(\\d+)/armv7",
  ],
};

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  for (const redirect of versionedRedirects) {
    const match = pathname.match(redirect.source);

    if (match) {
      const version = match[1];
      const destination = redirect.destination.replace(/:version/g, version);
      return NextResponse.redirect(destination);
    }
  }

  return NextResponse.next();
}
