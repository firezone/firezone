import gravatar from "@/lib/gravatar";
import type { BlogFrontmatter } from "@/types/frontmatter";

// Resolve a blog post's author avatar URL. Prefers an explicit
// authorAvatarSrc; falls back to a Gravatar generated from authorEmail.
// `asBlogFrontmatter` already guarantees one of the two is set.
export function blogAuthorAvatar(fm: BlogFrontmatter): string {
  if (fm.authorAvatarSrc) return fm.authorAvatarSrc;
  // Non-null asserted: asBlogFrontmatter ran the existence check.
  return gravatar(fm.authorEmail!);
}
