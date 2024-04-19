import Content from "./readme.mdx";
import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Use Cases • Firezone Docs",
  description:
    "Learn how Firezone can be used to solve common access challenges for your organization.",
};

export default function Page() {
  return (
    <>
      <Content />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
