import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";
import gravatar from "@/lib/gravatar";

export const metadata: Metadata = {
  title: "Release 0.5.0 • Firezone Blog",
  description: "Firezone 0.5.0 Release",
};

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder & CEO"
      authorEmail="jamil@firezone.dev"
      authorAvatarSrc={gravatar("jamil@firezone.dev")}
      title="Firezone 0.5.0 Released!"
      date="July 25, 2022"
    >
      <Content />
    </Post>
  );
}
