"use client";

import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import gravatar from "@/lib/gravatar";

export default function Page() {
  return (
    <Post
      authorName="Brian Manifold"
      authorTitle="Full Stack Engineer"
      authorAvatarSrc={gravatar("bmanifold@firezone.dev")}
      title="A New Look for Firezone"
      date="April 14, 2026"
    >
      <Content />
    </Post>
  );
}
