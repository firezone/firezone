"use client";

import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import gravatar from "@/lib/gravatar";

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder"
      authorAvatarSrc={gravatar("jamil@firezone.dev")}
      title="Firezone 1.0"
      date="July 14, 2023"
    >
      <Content />
    </Post>
  );
}
