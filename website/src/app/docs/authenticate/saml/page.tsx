import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "SAML 2.0 • Firezone Docs",
  description:
    "Enforce single sign-on with your identity provider. Integrate providers like Okta, Google, OneLogin, and JumpCloud using Firezone's SAML 2.0 connector.",
};

export default function Page() {
  return <Content />;
}
