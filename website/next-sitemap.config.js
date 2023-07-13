/** @type {import('next-sitemap').IConfig} */
module.exports = {
  siteUrl: process.env.SITE_URL || "https://firezone.dev",
  generateRobotsTxt: true, // (optional)
  // ...other options
};
