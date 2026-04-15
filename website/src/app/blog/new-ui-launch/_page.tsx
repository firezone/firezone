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
      date="April 14, 2026"
    >
      <Content />
    </Post>
  );
}
