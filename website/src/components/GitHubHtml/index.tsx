export default function GitHubHtml({ html }: { html: string }) {
  return (
    <div className="github-html" dangerouslySetInnerHTML={{ __html: html }} />
  );
}
