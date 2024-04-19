import { Metadata } from "next";
import LastUpdated from "@/components/LastUpdated";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Use Cases: Secure Host Access • Firezone Docs",
  description: "Use Firezone to secure access to a single host.",
};

export default function Page() {
  return (
    <>
      <_Page />
      <LastUpdated dirname={__dirname} />
    </>
  );
}
