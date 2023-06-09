import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Omnibus Configurations • Firezone Docs",
  description: "Configuration of Omnibus-based deployments of Firezone.",
};

export default function Page() {
  return <Content />;
}
