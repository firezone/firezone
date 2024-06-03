"use client";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import gravatar from "@/lib/gravatar";

export default function _Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder"
      authorEmail="jamil@firezone.dev"
      authorAvatarSrc={gravatar("jamil@firezone.dev")}
      title="May 2024 Update"
      date="2024-05-01"
    >
      <Content />
    </Post>
  );
}
