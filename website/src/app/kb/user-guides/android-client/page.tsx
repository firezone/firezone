import Content from "./readme.mdx";
import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";

export const metadata: Metadata = {
  title: "Android & ChromeOS Client • Firezone Docs",
  description: "How to install and use the Firezone Android & ChromeOS Client.",
};

export default function Page() {
  return (
    <>
      <Content />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
