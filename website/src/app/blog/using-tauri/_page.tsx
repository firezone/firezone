"use client";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export default function _Page() {
  return (
    <Post
      authorName="ReactorScram"
      authorTitle="Senior Systems Engineer"
      authorAvatarSrc="/images/avatars/reactorscram.png"
      title="Using Tauri to build a cross-platform security app"
      date="2024-06-11"
    >
      <Content />
    </Post>
  );
}
