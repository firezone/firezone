"use client";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export default function _Page() {
  return (
    <Post
      authorName="ReactorScram"
      authorTitle="Senior Systems Engineer"
      authorEmail=""
      title="(Draft) Desktop Integration"
      date="2024-05-30"
    >
      <Content />
    </Post>
  );
}
