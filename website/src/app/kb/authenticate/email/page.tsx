import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Email Authentication",
  description:
    "Set up Firezone email authentication with one-time passcodes. Send a 6-digit OTP to users for sign-in — see the email setup guide.",
};

export default function Page() {
  return <Content />;
}
