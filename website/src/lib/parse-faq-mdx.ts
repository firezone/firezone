import { readFile } from "node:fs/promises";

// Parse `#### Question` / paragraph pairs out of the FAQ MDX so the
// FAQ JSON-LD schema is generated from the same source as the visible
// page content. Hand-maintaining a parallel array drifted in practice
// (mismatched wording, stale answers).
//
// Rules:
//   - A `#### text` line starts a Q&A entry. The text (question) is
//     trimmed of trailing punctuation-preserving whitespace.
//   - The answer is the prose that follows up to the next `####`, `###`,
//     `##`, `#`, or end of file. Inline markdown is collapsed to plain
//     text: links become their visible label, bold/italic/code markers
//     are stripped, hard line breaks become single spaces.
export type FaqEntry = { question: string; answer: string };

export async function parseFaqEntries(mdxPath: string): Promise<FaqEntry[]> {
  const raw = await readFile(mdxPath, "utf8");
  const lines = stripFrontmatter(raw).split(/\r?\n/);
  const entries: FaqEntry[] = [];

  let current: { question: string; answerLines: string[] } | null = null;
  for (const line of lines) {
    const q = line.match(/^####\s+(.+?)\s*$/);
    if (q) {
      if (current) entries.push(finalize(current));
      current = { question: q[1].trim(), answerLines: [] };
      continue;
    }
    // Any other heading ends the current Q&A.
    if (/^#{1,3}\s/.test(line)) {
      if (current) {
        entries.push(finalize(current));
        current = null;
      }
      continue;
    }
    if (current) current.answerLines.push(line);
  }
  if (current) entries.push(finalize(current));

  return entries.filter((e) => e.answer.length > 0);
}

function finalize(c: { question: string; answerLines: string[] }): FaqEntry {
  const answer = c.answerLines
    .join(" ")
    .replace(/\s+/g, " ")
    // Inline links: [label](href) -> label
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    // Bold/italic/code markers
    .replace(/(\*\*|__|\*|_|`)/g, "")
    .trim();
  return { question: c.question, answer };
}

function stripFrontmatter(src: string): string {
  if (!src.startsWith("---")) return src;
  const end = src.indexOf("\n---", 3);
  if (end < 0) return src;
  return src.slice(end + 4);
}
