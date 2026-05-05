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

function templateSuffixFor(file) {
  const rel = relative(APP_DIR, file).split(sep);
  if (rel[0] === "kb") return " • Firezone Docs";
  if (rel[0] === "blog") return " • Firezone Blog";
  return " • Firezone";
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

const files = await walk(APP_DIR);
const violations = [];
const titleSeen = new Map();
const descSeen = new Map();
const fileMetaCache = new Map();

for (const file of files) {
  const src = await readFile(file, "utf8");
  fileMetaCache.set(file, extractMetadata(src));
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
    const rendered = titleKind === "absolute" ? title : `${title}${suffix}`;
    if (rendered.length > TITLE_MAX) {
      violations.push(
        `${rel}: rendered title is ${rendered.length} chars (max ${TITLE_MAX}): "${rendered}"`
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
}

if (violations.length === 0) {
  console.log(`SEO check passed (${files.length} files inspected).`);
  process.exit(0);
}

console.error(`SEO check failed (${violations.length} violations):\n`);
for (const v of violations) console.error(`  - ${v}`);
process.exit(1);
