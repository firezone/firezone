import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Uninstall • Firezone Docs",
  description: "Firezone can be uninstalled in a few simple steps.",
};

export default function Page() {
  return <Content />;
}
