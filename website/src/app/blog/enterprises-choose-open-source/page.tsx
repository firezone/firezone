import Image from "next/image";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Enterprises choose open source • Firezone Blog",
  description: "Why enterprises choose open source software",
};

export default function Page() {
  return (
    <Post
      authorName="Jeff Spencer"
      authorTitle=""
      authorEmail="jeff@firezone.dev"
      title="Enterprises choose open source"
      date="December 6, 2023"
    >
      <Content />
    </Post>
  );
}
