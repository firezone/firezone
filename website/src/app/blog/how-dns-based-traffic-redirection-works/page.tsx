import _Page from "./_page";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "How DNS-Based Traffic Redirection Works • Firezone Blog",
  description:
    "The history of DNS, the security issues that plague it, and how Firezone solves them.",
};

export default function Page() {
  return <_Page />;
}
