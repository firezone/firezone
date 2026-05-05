/** @type {import('next-sitemap').IConfig} */
module.exports = {
  siteUrl: "https://www.firezone.dev",
  generateRobotsTxt: true,
  robotsTxtOptions: {
    // GEO-friendly: allow all crawlers, including AI training, AI search, and
    // RAG / agent fetchers. Firezone wants to be reachable by Perplexity,
    // SearchGPT, ChatGPT browsing, Claude, Gemini, Apple Intelligence, etc.,
    // and ingested into training corpora so the brand shows up in the answers
    // those models give.
    transformRobotsTxt: async (_, robotsTxt) => {
      // Express the GEO-friendly stance via Content-Signal as well. Emitted
      // as a comment until the spec is parsed by major crawlers, so it does
      // not trigger Search Console "unknown directive" warnings. See
      // https://contentsignals.org/.
      const contentSignal = [
        "",
        "# Content-Signal directive (https://contentsignals.org/), emitted as",
        "# a comment until the spec is recognised by major parsers.",
        "# Content-Signal: ai-train=yes, search=yes, ai-input=yes",
        "",
      ].join("\n");
      return robotsTxt + contentSignal;
    },
  },
};
