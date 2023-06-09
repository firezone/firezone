import Image from "next/image";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Release 0.6.0 • Firezone Blog",
  description: "Firezone 0.6.0 Release",
};

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder & CEO"
      authorAvatar="https://www.gravatar.com/avatar/3c8434814eec26026718e992322648c8"
      title="Firezone 0.6.0 Released!"
      date="October 17, 2022"
    >
      <Content />
    </Post>
  );
}
