import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "OIDC Authentication",
  description:
    "Configure Firezone authentication with any OIDC identity provider. Set up SSO using OpenID Connect with this step-by-step setup guide.",
};

export default function Page() {
  return <Content />;
}
