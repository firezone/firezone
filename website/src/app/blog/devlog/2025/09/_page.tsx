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
      title="September 2025 Update"
      date="2025-09-30"
    >
      <Content />
    </Post>
  );
}
