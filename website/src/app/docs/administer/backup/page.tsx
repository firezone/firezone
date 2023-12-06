import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Backup • Firezone Docs",
  description: "Firezone Documentation",
};

export default function Page() {
  return <_Page />;
}
