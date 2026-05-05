import { Metadata } from "next";
import _Page from "./_page";

export const metadata: Metadata = {
  title: "PII Leak Incident Post-Mortem (Nov 2025)",
  description:
    "Read the post-mortem on Firezone's November 28, 2025 PII leak — affected users, impact, root cause, and the remediation steps we took.",
};

export default function Page() {
  return <_Page />;
}
