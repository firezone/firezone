import { Metadata } from "next";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export const metadata: Metadata = {
  title: "Release 0.6.0 • Firezone Blog",
  description: "Firezone 0.6.0 Release",
};

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder & CEO"
      authorEmail="jamil@firezone.dev"
      title="Firezone 0.6.0 Released!"
      date="October 17, 2022"
    >
      <Content />
    </Post>
  );
}
