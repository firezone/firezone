import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Configure DNS",
  description:
    "Configure Firezone split DNS to resolve internal hostnames over your private network. Set up DNS resources — follow the configuration guide.",
};

export default function Page() {
  return <Content />;
}
