import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "OpenID Connect • Firezone Docs",
  description:
    "Setup single sign-on with your identity provider. Integrate providers like Okta, Google, Azure, and JumpCloud using Firezone's OpenID Connect (OIDC) connector.",
};

export default function Page() {
  return <Content />;
}
