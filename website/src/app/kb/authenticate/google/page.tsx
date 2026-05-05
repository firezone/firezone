import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Google Workspace Authentication",
  description:
    "Configure Firezone SSO with Google Workspace using OAuth. Authenticate users against your Google directory — follow the setup guide.",
};

export default function Page() {
  return <_Page />;
}
