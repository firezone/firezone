/** @type {import('next-sitemap').IConfig} */
module.exports = {
  siteUrl: "https://www.firezone.dev",
  generateRobotsTxt: true,
  robotsTxtOptions: {
    transformRobotsTxt: async (_, robotsTxt) => {
      return robotsTxt.replace(
        /^User-agent: \*$/m,
        "User-agent: *\nContent-Signal: ai-train=yes, search=yes, ai-input=yes"
      );
    },
  },
};
