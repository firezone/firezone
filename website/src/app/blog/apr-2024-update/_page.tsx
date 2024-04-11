"use client";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export default function _Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder"
      authorEmail="jamil@firezone.dev"
      title="April 2024 Update: GA"
      date="2024-04-01"
    >
      <Content />
    </Post>
  );
}
