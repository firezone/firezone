import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Regenerate Secret Keys",
  description: "Instructions for renegerating application secret keys.",
};

export default function Page() {
  return <Content />;
}
