"use client";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export default function _Page() {
  return (
    <Post
      authorName="Gabriel Steinberg"
      authorTitle="Senior Backend Engineer"
      authorEmail="gabriel@firezone.dev"
      title="How DNS-Based Traffic Routing Works"
      date="2024-04-30"
    >
      <Content />
    </Post>
  );
}
