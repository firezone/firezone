import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Regenerate Secret Keys • Firezone Docs",
  description: "Instructions for renegerating application secret keys.",
};

export default function Page() {
  return <Content />;
}
