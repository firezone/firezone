import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Migrate to Docker",
  description:
    "Migrating to Docker is a simple process that can be done in a few steps.",
};

export default function Page() {
  return <Content />;
}
