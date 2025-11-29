import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "Nov 28 2025 Incident Post-Mortem • Firezone Blog",
  description: `On November 28, 2025, a PII leak incident occurred affecting a small
    number of user names and email addresses. This post-mortem details the
    incident, its impact, and the steps we're taking to prevent future
    occurrences.`,
};

export default function Page() {
  return <_Page />;
}
