import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Onelogin OIDC • Firezone Docs",
  description:
    "Enforce 2FA/MFA for users of Firezone's WireGuard®-based secure access platform. This guide walks through integrating Onelogin for single sign-on using OpenID Connect (OIDC).",
};

export default function Page() {
  return <_Page />;
}
