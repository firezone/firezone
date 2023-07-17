import Image from "next/image";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone 1.0 • Firezone Blog",
  description: "Announcing the 1.0 early access program",
};

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder & CEO"
      authorEmail="jamil@firezone.dev"
      title="Firezone 1.0"
      date="July 14, 2023"
    >
      <Content />
    </Post>
  );
}
