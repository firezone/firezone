import type { Metadata } from "next";
import type { MdxFrontmatter } from "@/types/frontmatter";

// Map MDX frontmatter to Next's Metadata shape. Frontmatter is plain YAML so
// we encode the absolute-title flag as `titleAbsolute: true` rather than the
// nested `title: { absolute: ... }` form Next expects. Without this helper
// the flag is silently dropped and the page falls back to the layout's
// title template.
export function metadataFromFrontmatter(frontmatter: MdxFrontmatter): Metadata {
  const {
    titleAbsolute,
    title,
    description,
    // postTitle is the in-article H1; it must not leak into Metadata.
    postTitle: _postTitle,
    // Post props feed the <Post> wrapper, not Next's Metadata.
    authorName: _authorName,
    authorTitle: _authorTitle,
    authorEmail: _authorEmail,
    authorAvatarSrc: _authorAvatarSrc,
    date: _date,
  } = frontmatter;
  void _postTitle;
  void _authorName;
  void _authorTitle;
  void _authorEmail;
  void _authorAvatarSrc;
  void _date;

  const base: Metadata = {};
  if (description !== undefined) base.description = description;
  if (titleAbsolute && typeof title === "string") {
    return { ...base, title: { absolute: title } };
  }
  if (typeof title === "string") {
    return { ...base, title };
  }
  return base;
}
