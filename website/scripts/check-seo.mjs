#!/usr/bin/env node
import { readdir, readFile } from "node:fs/promises";
import { join, relative, sep } from "node:path";

const APP_DIR = join(process.cwd(), "src", "app");
const TITLE_MAX = 60;
const DESC_MAX = 155;

async function walk(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await walk(path)));
    else if (entry.name === "page.tsx" || entry.name === "layout.tsx")
      out.push(path);
  }
  return out;
}

async function findInheritedMetadata(pageFile, fileMetaCache) {
  let dir = pageFile.replace(/\/page\.tsx$/, "");
  while (dir.length >= APP_DIR.length) {
    const layoutPath = join(dir, "layout.tsx");
    if (fileMetaCache.has(layoutPath)) {
      const meta = fileMetaCache.get(layoutPath);
      if (meta && (meta.title || meta.description)) return meta;
    }
    if (dir === APP_DIR) break;
    dir = dir.substring(0, dir.lastIndexOf("/"));
  }
  return null;
}

function extractH1FromTsx(source) {
  const m = source.match(/<h1\b[^>]*>\s*([^<{]+?)\s*<\/h1>/);
  if (!m) return null;
  return m[1].replace(/\s+/g, " ").trim();
}

function extractH1FromMdx(source) {
  for (const line of source.split(/\r?\n/)) {
    const m = line.match(/^#\s+(.+?)\s*$/);
    if (m) return m[1].trim();
  }
  return null;
}

function extractPostTitle(source) {
  const m = source.match(/<Post\b[\s\S]*?\stitle="([^"]+)"/);
  return m ? m[1].trim() : null;
}

function extractPostTitleFromFrontmatter(source) {
  const fm = extractFrontmatter(source);
  if (!fm) return null;
  return fm.postTitle ?? null;
}

async function findH1(pageFile, fileSourceCache) {
  const src = fileSourceCache.get(pageFile);
  const rel = relative(APP_DIR, pageFile).split(sep);

  if (rel[0] === "kb") {
    const mdxPath = join(pageFile.replace(/\/page\.tsx$/, ""), "readme.mdx");
    try {
      const mdx = await readFile(mdxPath, "utf8");
      const h1 = extractH1FromMdx(mdx);
      if (h1) return { h1, source: relative(process.cwd(), mdxPath) };
    } catch {
      /* no sibling readme */
    }
  }

  if (rel[0] === "blog") {
    const postTitle = extractPostTitle(src);
    if (postTitle)
      return { h1: postTitle, source: relative(process.cwd(), pageFile) };
    const mdxPath = join(pageFile.replace(/\/page\.tsx$/, ""), "readme.mdx");
    try {
      const mdx = await readFile(mdxPath, "utf8");
      const fmTitle = extractPostTitleFromFrontmatter(mdx);
      if (fmTitle)
        return { h1: fmTitle, source: relative(process.cwd(), mdxPath) };
    } catch {
      /* no readme */
    }
  }

  const inPage = extractH1FromTsx(src);
  if (inPage) return { h1: inPage, source: relative(process.cwd(), pageFile) };

  let dir = pageFile.replace(/\/page\.tsx$/, "");
  while (dir.length >= APP_DIR.length) {
    const layoutPath = join(dir, "layout.tsx");
    if (fileSourceCache.has(layoutPath)) {
      const layoutH1 = extractH1FromTsx(fileSourceCache.get(layoutPath));
      if (layoutH1)
        return { h1: layoutH1, source: relative(process.cwd(), layoutPath) };
    }
    if (dir === APP_DIR) break;
    dir = dir.substring(0, dir.lastIndexOf("/"));
  }

  return null;
}

function bareTitleForCompare(title) {
  // Strip the trailing site-name suffix from a fully rendered title so we
  // can compare it against an H1. Matches either separator we've ever used
  // (current pipe, legacy bullet) and an optional section qualifier
  // ("Firezone Docs", "Firezone Blog").
  return title.replace(/\s*[|•]\s*Firezone(\s+\w+)?\s*$/, "").trim();
}

const BARE_TITLE_ASSERTIONS = [
  ["Zero Trust Access That Scales | Firezone", "Zero Trust Access That Scales"],
  ["Authentication | Firezone Docs", "Authentication"],
  ["Firezone 1.0 | Firezone Blog", "Firezone 1.0"],
  // Legacy separator — we changed templates from • to | but old assets and
  // out-of-tree references may still use bullets. Keep matching them.
  ["Old Page • Firezone Docs", "Old Page"],
  // No suffix to strip.
  ["Standalone Title", "Standalone Title"],
];

const H1_PARSE_ASSERTIONS = [
  {
    file: "src/app/kb/authenticate/readme.mdx",
    extract: extractH1FromMdx,
    expected: "Authentication",
  },
  {
    file: "src/app/pricing/layout.tsx",
    extract: extractH1FromTsx,
    expected: "Firezone Pricing & Plans",
  },
  {
    file: "src/app/blog/jan-2024-update/readme.mdx",
    extract: extractPostTitleFromFrontmatter,
    expected: "January 2024 Update",
  },
  {
    file: "src/app/page.tsx",
    extract: extractH1FromTsx,
    expected: "Upgrade your VPN to zero-trust access",
  },
];

function templateSuffixFor(file) {
  const rel = relative(APP_DIR, file).split(sep);
  if (rel[0] === "kb") return " | Firezone Docs";
  if (rel[0] === "blog") return " | Firezone Blog";
  return " | Firezone";
}

function extractMetadata(source) {
  const block = source.match(
    /export\s+const\s+metadata\s*:\s*Metadata\s*=\s*\{([\s\S]*?)\n\};/
  );
  if (!block) return null;
  const body = block[1];

  let title = null;
  let titleKind = null;
  const absoluteMatch = body.match(
    /title\s*:\s*\{[^}]*?absolute\s*:\s*"([^"]*)"/
  );
  if (absoluteMatch) {
    title = absoluteMatch[1];
    titleKind = "absolute";
  } else {
    const stringMatch = body.match(/title\s*:\s*"([^"]*)"/);
    if (stringMatch) {
      title = stringMatch[1];
      titleKind = "string";
    } else {
      const defaultMatch = body.match(
        /title\s*:\s*\{[^}]*?default\s*:\s*"([^"]*)"/
      );
      if (defaultMatch) {
        title = defaultMatch[1];
        titleKind = "default";
      }
    }
  }

  const descMatch = body.match(/description\s*:\s*(?:\n\s*)?"([^"]*)"/);
  const description = descMatch ? descMatch[1] : null;

  return { title, titleKind, description };
}

function extractFrontmatter(source) {
  const m = source.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return null;
  const fields = {};
  const lines = m[1].split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const km = lines[i].match(/^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*)$/);
    if (!km) continue;
    const key = km[1];
    let raw = km[2].trim();
    // Prettier wraps long strings across continuation lines that are indented.
    // Collect them while the next line is indented (and not a new key).
    while (
      i + 1 < lines.length &&
      /^\s+\S/.test(lines[i + 1]) &&
      !/^\s+[A-Za-z][A-Za-z0-9_-]*\s*:/.test(lines[i + 1])
    ) {
      i++;
      raw += " " + lines[i].trim();
    }
    fields[key] = unquoteYaml(raw);
  }
  return fields;
}

function unquoteYaml(value) {
  let v = value.trim();
  if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
    v = v.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }
  return v;
}

async function readFrontmatterMetadata(pageFile) {
  const mdxPath = join(pageFile.replace(/\/page\.tsx$/, ""), "readme.mdx");
  try {
    const mdx = await readFile(mdxPath, "utf8");
    const fm = extractFrontmatter(mdx);
    if (!fm || (!fm.title && !fm.description)) return null;
    return {
      title: fm.title ?? null,
      titleKind: fm.titleAbsolute === "true" ? "absolute" : "string",
      description: fm.description ?? null,
    };
  } catch {
    return null;
  }
}

function pageReferencesFrontmatter(source) {
  return (
    /\bfrontmatter\b/.test(source) && /from\s+"\.\/readme\.mdx"/.test(source)
  );
}

const files = await walk(APP_DIR);
const violations = [];
const titleSeen = new Map();
const descSeen = new Map();
const fileMetaCache = new Map();
const fileSourceCache = new Map();

for (const file of files) {
  const src = await readFile(file, "utf8");
  fileSourceCache.set(file, src);
  let meta = extractMetadata(src);
  if (
    (!meta || (!meta.title && !meta.description)) &&
    pageReferencesFrontmatter(src)
  ) {
    const fmMeta = await readFrontmatterMetadata(file);
    if (fmMeta) meta = fmMeta;
  }
  fileMetaCache.set(file, meta);
}

for (const [input, expected] of BARE_TITLE_ASSERTIONS) {
  const actual = bareTitleForCompare(input);
  if (actual !== expected) {
    violations.push(
      `bareTitleForCompare regression: "${input}" → "${actual}" (expected "${expected}")`
    );
  }
}

for (const { file, extract, expected } of H1_PARSE_ASSERTIONS) {
  const abs = join(process.cwd(), file);
  let actual = null;
  try {
    actual = extract(await readFile(abs, "utf8"));
  } catch {
    /* fall through */
  }
  if (actual !== expected) {
    violations.push(
      `H1 parser regression on ${file}: expected "${expected}", got ${
        actual === null ? "null" : `"${actual}"`
      }`
    );
  }
}

for (const file of files) {
  let meta = fileMetaCache.get(file);
  const isLayout = file.endsWith("layout.tsx");
  if (!meta && !isLayout) {
    meta = await findInheritedMetadata(file, fileMetaCache);
    if (meta) continue; // page inherits from a layout — already linted there
  }
  if (!meta) {
    if (!isLayout)
      violations.push(
        `${relative(process.cwd(), file)}: missing metadata export`
      );
    continue;
  }

  const { title, titleKind, description } = meta;
  const rel = relative(process.cwd(), file);
  const suffix = templateSuffixFor(file);

  if (!isLayout) {
    if (!title) violations.push(`${rel}: missing title`);
    if (!description) violations.push(`${rel}: missing description`);
  }

  if (title) {
    // `{ default: "..." }` is the layout's own resolved title — Next.js
    // does NOT apply the same layout's template to it. Treat it like
    // absolute so we don't double-append the suffix.
    const skipSuffix = titleKind === "absolute" || titleKind === "default";
    const rendered = skipSuffix ? title : `${title}${suffix}`;
    if (rendered.length > TITLE_MAX) {
      violations.push(
        `${rel}: rendered title is ${rendered.length} chars (max ${TITLE_MAX}): "${rendered}"`
      );
    }
    if (/[—–]/.test(rendered)) {
      violations.push(
        `${rel}: title contains em/en dash (Google sometimes drops them); rewrite with a colon or comma: "${rendered}"`
      );
    }
    if (!isLayout) {
      const prev = titleSeen.get(rendered);
      if (prev)
        violations.push(`${rel}: duplicate title with ${prev}: "${rendered}"`);
      else titleSeen.set(rendered, rel);
    }
  }

  if (description) {
    if (description.length > DESC_MAX) {
      violations.push(
        `${rel}: description is ${description.length} chars (max ${DESC_MAX})`
      );
    }
    if (!isLayout) {
      const prev = descSeen.get(description);
      if (prev)
        violations.push(
          `${rel}: duplicate description with ${prev}: "${description}"`
        );
      else descSeen.set(description, rel);
    }
  }

  if (!isLayout && title) {
    const found = await findH1(file, fileSourceCache);
    if (found) {
      const titleBare = bareTitleForCompare(title);
      if (
        found.h1.toLocaleLowerCase() === titleBare.toLocaleLowerCase() ||
        found.h1.toLocaleLowerCase() === title.toLocaleLowerCase()
      ) {
        violations.push(
          `${rel}: H1 matches title — H1 "${found.h1}" (from ${found.source}) duplicates page title`
        );
      }
    }
  }
}

if (violations.length === 0) {
  console.log(`SEO check passed (${files.length} files inspected).`);
  process.exit(0);
}

console.error(`SEO check failed (${violations.length} violations):\n`);
for (const v of violations) console.error(`  - ${v}`);
process.exit(1);
