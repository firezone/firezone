"use client";

import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export default function Page() {
  return (
    <Post
      authorName="Brian Manifold"
      authorTitle="Senior Fullstack Engineer"
      authorAvatarSrc="/images/avatars/brian.png"
      title="A New Look for Firezone"
      date="2026-04-15"
    >
      <Content />
    </Post>
  );
}
