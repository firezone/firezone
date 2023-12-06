"use client";

import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder & CEO"
      authorEmail="jamil@firezone.dev"
      title="Firezone 1.0"
      date="July 14, 2023"
    >
      <Content />
    </Post>
  );
}
