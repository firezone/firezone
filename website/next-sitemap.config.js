/** @type {import('next-sitemap').IConfig} */
module.exports = {
  siteUrl: "https://www.firezone.dev",
  generateRobotsTxt: true,
  robotsTxtOptions: {
    transformRobotsTxt: async (_, robotsTxt) => {
      // Append Content-Signal directive (https://contentsignals.org/)
      const contentSignal = [
        "",
        "# Content-Signal directive (https://contentsignals.org/)",
        "Content-Signal: ai-train=no, search=yes, ai-input=no",
        "",
      ].join("\n");
      return robotsTxt + contentSignal;
    },
  },
};
