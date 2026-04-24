/** @type {import('next-sitemap').IConfig} */
module.exports = {
  siteUrl: "https://www.firezone.dev",
  generateRobotsTxt: true,
  robotsTxtOptions: {
    transformRobotsTxt: async (_, robotsTxt) => {
      // Append Content-Signal directive (https://contentsignals.org/)
      return (
        robotsTxt +
        "\n# Content-Signal directive (https://contentsignals.org/)\nContent-Signal: ai-train=no, search=yes, ai-input=no\n"
      );
    },
  },
};
