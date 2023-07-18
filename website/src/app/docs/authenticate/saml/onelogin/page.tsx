import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Onelogin SAML • Firezone Docs",
  description:
    "Enforce 2FA/MFA for users of Firezone's WireGuard®-based secure access platform. This guide walks through integrating Onelogin for single sign-on using the SAML 2.0 connector.",
};

export default function Page() {
  return <Content />;
}
