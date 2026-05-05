import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Microsoft Entra ID Authentication",
  description:
    "Configure Firezone SSO with Microsoft Entra ID (Azure AD). Authenticate users against your Entra tenant — follow the setup guide.",
};

export default function Page() {
  return <_Page />;
}
