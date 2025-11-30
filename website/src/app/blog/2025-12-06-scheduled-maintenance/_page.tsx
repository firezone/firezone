import Post from "@/components/Blog/Post";
import Content from "./readme.mdx";

export default function _Page() {
  return (
    <Post
      authorName="Firezone Team"
      authorTitle="Firezone"
      authorAvatarSrc="/images/logo-main-light.svg"
      title="Scheduled Maintenance - December 6, 2025"
      date="December 2, 2025"
    >
      <Content />
    </Post>
  );
}
