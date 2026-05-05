import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Authentication Overview",
  description:
    "Firezone supports Google Workspace, Okta, Microsoft Entra ID, OIDC, and email authentication methods.",
};

export default function Page() {
  return <Content />;
}
