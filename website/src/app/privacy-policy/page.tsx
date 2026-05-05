import { Metadata } from "next";
import TermlyContent from "@/components/TermlyContent";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "Read how Firezone collects, uses, and protects your personal information across our software, services, and website.",
};

export default function Page() {
  return (
    <div className="mx-auto max-w-screen-md pt-14">
      <TermlyContent id="1aa082a3-aba1-4169-b69b-c1d1b42b7a48" />
    </div>
  );
}
