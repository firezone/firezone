/** @type {import('next-sitemap').IConfig} */
module.exports = {
  siteUrl: "https://www.firezone.dev",
  generateRobotsTxt: true,
  robotsTxtOptions: {
    transformRobotsTxt: async (_, robotsTxt) => {
      // Append Content-Signal directives (https://contentsignals.org/)
      return (
        robotsTxt +
        "\n# Content Signals (https://contentsignals.org/)\nContent-Signal: ai-train=no, search=yes, ai-input=no\n"
      );
    },
  },
};
