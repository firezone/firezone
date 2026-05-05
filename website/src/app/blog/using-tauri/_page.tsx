"use client";
import Post from "@/components/Blog/Post";
import Content, { frontmatter } from "./readme.mdx";
import { blogAuthorAvatar } from "@/lib/blog-author-avatar";
import { asBlogFrontmatter } from "@/types/frontmatter";

export default function _Page() {
  const fm = asBlogFrontmatter(frontmatter);
  return (
    <Post
      authorName={fm.authorName}
      authorTitle={fm.authorTitle}
      authorAvatarSrc={blogAuthorAvatar(fm)}
      title={fm.postTitle ?? fm.title}
      date={fm.date}
    >
      <Content />
    </Post>
  );
}
