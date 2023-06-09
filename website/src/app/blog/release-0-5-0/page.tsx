import Image from "next/image";
import BlogPost from "@/components/BlogPost";
import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Release 0.5.0 • Firezone Blog",
  description: "Firezone 0.5.0 Release",
};

export default function Page() {
  return (
    <BlogPost>
      <Content />
    </BlogPost>
  );
}
