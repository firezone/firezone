"use client";
import SyntaxHighlighter from "react-syntax-highlighter";
import { a11yDark } from "react-syntax-highlighter/dist/esm/styles/hljs";

export default function CodeBlock({
  language,
  codeString,
}: {
  language: string;
  codeString: string;
}) {
  return (
    <SyntaxHighlighter language={language} style={a11yDark}>
      {codeString}
    </SyntaxHighlighter>
  );
}
