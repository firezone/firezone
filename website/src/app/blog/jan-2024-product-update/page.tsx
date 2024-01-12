import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Jan 2024 Product Update • Firezone Blog",
  description: "January 2024 Product Update",
};

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder"
      authorEmail="jamil@firezone.dev"
      title="January 2024 Product Update"
      date="2024-01-01"
    >
      <Content />
    </Post>
  );
}
