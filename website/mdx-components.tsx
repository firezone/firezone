import type { MDXComponents } from "mdx/types";
import { isValidElement, type ReactElement } from "react";
import CodeBlock from "@/components/CodeBlock";
import Mermaid from "@/components/Mermaid";

type CodeProps = { className?: string; children?: unknown };

function extractText(node: unknown): string {
  if (typeof node === "string") return node;
  if (Array.isArray(node)) return node.map(extractText).join("");
  if (isValidElement(node)) {
    return extractText((node.props as { children?: unknown }).children);
  }
  return "";
}

export function useMDXComponents(components: MDXComponents): MDXComponents {
  return {
    ...components,
    pre: ({ children }) => {
      if (isValidElement(children)) {
        const codeProps = (children as ReactElement<CodeProps>).props;
        if (codeProps.className?.includes("language-mermaid")) {
          return <Mermaid chart={extractText(codeProps.children)} />;
        }
      }
      return <CodeBlock>{children}</CodeBlock>;
    },
  };
}
