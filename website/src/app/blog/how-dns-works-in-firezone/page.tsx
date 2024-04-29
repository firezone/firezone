import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "How DNS Routing Works • Firezone Blog",
  description:
    "A bit about the history of DNS, the security issues that plague it, and how Firezone uniquely solves these.",
};

export default function Page() {
  return <_Page />;
}
