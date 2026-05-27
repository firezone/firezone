import { Metadata } from "next";
import TermlyContent from "@/components/TermlyContent";

export const metadata: Metadata = {
  title: "Terms of Service",
  description:
    "Review the legal terms governing your use of Firezone software, services, and website. Read the full terms of service.",
};

export default function Page() {
  return (
    <div className="mx-auto max-w-screen-md pt-14">
      <TermlyContent id="2a4e649b-b8a8-41b1-b32a-dad5a2e65d15" />
    </div>
  );
}
