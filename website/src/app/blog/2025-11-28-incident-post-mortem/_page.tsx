import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";
import gravatar from "@/lib/gravatar";

export default function _Page() {
  return (
    <Post
      authorName="Jamil Bou Kheir"
      authorTitle="Founder"
      authorAvatarSrc={gravatar("jamil@firezone.dev")}
      title="Nov 28 2025 Incident Post-Mortem"
      date="2025-11-28"
    >
      <Content />
    </Post>
  );
}
