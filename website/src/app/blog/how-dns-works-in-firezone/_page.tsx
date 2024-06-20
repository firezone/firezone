"use client";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import gravatar from "@/lib/gravatar";

export default function _Page() {
  return (
    <Post
      authorName="Gabriel Steinberg"
      authorTitle="Senior Backend Engineer"
      authorAvatarSrc={gravatar("gabriel@firezone.dev")}
      title="How DNS Works in Firezone"
      date="2024-05-08"
    >
      <Content />
    </Post>
  );
}
