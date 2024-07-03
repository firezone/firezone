import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import { Metadata } from "next";
import gravatar from "@/lib/gravatar";

export const metadata: Metadata = {
  title: "sans-IO: The secret to effective Rust for network services",
  description: "sans-IO: The secret to effective Rust for network services",
};

export default function Page() {
  return (
    <Post
      authorName="Thomas Eizinger"
      authorTitle="Distributed Systems Engineer"
      authorAvatarSrc={gravatar("thomas@firezone.dev")}
      title="sans-IO: The secret to effective Rust for network services"
      date="July 2, 2024"
    >
      <Content />
    </Post>
  );
}
