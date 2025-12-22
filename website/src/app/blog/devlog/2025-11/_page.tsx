"use client";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import gravatar from "@/lib/gravatar";

export default function _Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder"
      authorAvatarSrc={gravatar("jamil@firezone.dev")}
      title="November 2025 Devlog"
      date="2025-11-30"
    >
      <Content />
    </Post>
  );
}
