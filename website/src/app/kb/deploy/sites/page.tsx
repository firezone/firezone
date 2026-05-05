import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Sites",
  description:
    "Create Firezone Sites — shared network environments where Gateways and Resources live. Organize your infrastructure — see the Sites guide.",
};

export default function Page() {
  return <Content />;
}
