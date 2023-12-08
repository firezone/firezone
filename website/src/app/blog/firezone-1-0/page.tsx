import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone 1.0 • Firezone Blog",
  description: "Announcing the 1.0 early access program",
};

export default function Page() {
  return <_Page />;
}
