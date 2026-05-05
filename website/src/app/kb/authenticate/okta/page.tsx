import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Okta Authentication",
  description:
    "Configure Firezone SSO with Okta using OpenID Connect. Authenticate users against your Okta directory — follow the integration guide.",
};

export default function Page() {
  return <_Page />;
}
