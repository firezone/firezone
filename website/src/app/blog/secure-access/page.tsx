import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Secure remote access • Firezone",
  description: "Secure remote access makes remote work a win-win",
};

export default function Page() {
  return (
    <Post
      authorName="Jeff Spencer"
      authorTitle="Interim Head of Marketing"
      authorEmail="jeff@firezone.dev"
      title="Secure remote access makes remote work a win-win"
      date="2023-11-17"
    >
      <Content />
    </Post>
  );
}
