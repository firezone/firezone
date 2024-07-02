import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";
import gravatar from "@/lib/gravatar";

export const metadata: Metadata = {
  title: "Jan 2024 Update • Firezone Blog",
  description: "January 2024 Update",
};

export default function Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder"
      authorAvatarSrc={gravatar("jamil@firezone.dev")}
      title="January 2024 Update"
      date="2024-01-01"
    >
      <Content />
    </Post>
  );
}
