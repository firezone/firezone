// Strictly-typed shape of YAML frontmatter parsed by remark-mdx-frontmatter.
// Declaring the fields explicitly catches typos in MDX YAML at build time
// (e.g. `titleAbsolut: true` would no longer slip through). Add new fields
// here when introducing a new YAML key, and update `metadataFromFrontmatter`
// if the field should flow into Next's Metadata.
export interface MdxFrontmatter {
  // Page metadata flowing into Next's Metadata via metadataFromFrontmatter.
  title?: string;
  titleAbsolute?: boolean;
  description?: string;
  // Blog-specific fields. `postTitle` is the in-article H1 when it differs
  // from the metadata title; the rest feed the <Post> header.
  postTitle?: string;
  authorName?: string;
  authorTitle?: string;
  authorEmail?: string;
  authorAvatarSrc?: string;
  date?: string;
}

// Blog posts have stricter requirements than KB pages — they MUST have a
// title, an author (name + role) and a publication date so the visible
// <Post> header and the JSON-LD article schema render correctly. They
// must also expose an avatar via either an explicit authorAvatarSrc or
// an authorEmail (which is hashed into a Gravatar URL).
export interface BlogFrontmatter extends MdxFrontmatter {
  title: string;
  authorName: string;
  authorTitle: string;
  date: string;
}

// Runtime + type assertion. Throws at build time if a blog post readme.mdx
// is missing a required key. We only reject `undefined` (key absent), not
// empty strings — `authorTitle: ""` is a deliberate "no role" choice some
// authors make and should pass through. For fields where an empty string
// would render as visibly broken (title, authorName, date), we still require
// non-empty content.
export function asBlogFrontmatter(fm: MdxFrontmatter): BlogFrontmatter {
  if (!fm.title) throw new Error("blog frontmatter missing title");
  if (!fm.authorName) throw new Error("blog frontmatter missing authorName");
  if (fm.authorTitle === undefined)
    throw new Error("blog frontmatter missing authorTitle key");
  if (!fm.date) throw new Error("blog frontmatter missing date");
  if (!fm.authorEmail && !fm.authorAvatarSrc) {
    throw new Error("blog frontmatter must set authorEmail or authorAvatarSrc");
  }
  return fm as BlogFrontmatter;
}
