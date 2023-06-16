import Image from "next/image";
import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import NewsletterSignup from "@/components/NewsletterSignup";
import { Metadata } from "next";

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
      title="Firezone 0.5.0 Released!"
      date="July 25, 2022"
    >
      <Content />
      <div className="border-t border-gray-200 dark:border-gray-700 pt-8">
        <NewsletterSignup />
      </div>
    </Post>
  );
}
