// @ts-check
// Note: type annotations allow type checking and IDEs autocompletion

const lightCodeTheme = require("prism-react-renderer/themes/github");
const darkCodeTheme = require("prism-react-renderer/themes/dracula");

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "firezone",
  tagline: "Open-source secure remote access built on WireGuard®",
  url: "https://www.firezone.dev",
  baseUrl: "/",
  onBrokenLinks: "throw",
  onBrokenMarkdownLinks: "warn",
  trailingSlash: true,
  favicon: "img/favicon.ico",

  // GitHub pages deployment config.
  // If you aren't using GitHub pages, you don't need these.
  organizationName: "firezone", // Usually your GitHub org/user name.
  projectName: "firezone", // Usually your repo name.

  // Even if you don't use internalization, you can use this field to set useful
  // metadata like html lang. For example, if your site is Chinese, you may want
  // to replace 'en' with 'zh-Hans'.
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  // An array of scripts to load. The values can be either strings or plain
  // objects of attribute-value maps. The <script> tags will be inserted in the
  // HTML <head>. If you use a plain object, the only required attribute is src,
  // and any other attributes are permitted (each one should have boolean/string
  // values).
  //
  // Note that <script> added here are render-blocking, so you might want to
  // add async: true/defer: true to the objects.
  scripts: [
    {
      src: "/js/posthog.js",
      async: true,
    },
    {
      src: "//js.hs-scripts.com/23723443.js",
      async: true,
      defer: true,
    },
  ],

  plugins: [
    [
      '@docusaurus/plugin-client-redirects',
      {
        redirects: [
          {
            to: '/contact/newsletter',
            from: '/sales',
          },
        ],
      },
    ],
  ],

  themes: [],

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        pages: {
          routeBasePath: "/",
        },
        docs: {
          routeBasePath: "/docs",
          sidebarPath: require.resolve("./sidebars.js"),
          editUrl: "https://github.com/firezone/firezone/blob/master/www/",
          docLayoutComponent: "@theme/DocPage",
        },
        blog: {
          routeBasePath: "/blog",
          blogSidebarTitle: "All posts",
          blogSidebarCount: "ALL",
          showReadingTime: true,
        },
        theme: {
          customCss: require.resolve("./src/css/custom.css"),
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      navbar: {
        title: "firezone",
        logo: {
          alt: "Firezone Logo",
          src: "img/logo.svg",
        },
        items: [
          {
            href: "/docs",
            label: "Documentation",
            position: "left",
          },
          {
            href: "/blog",
            label: "Blog",
            position: "left",
          },
          // {
          //   href: "/pricing",
          //   label: "Pricing",
          //   position: "left",
          // },
          {
            href: "/contact/support",
            label: "Contact support",
            position: "right",
            "aria-label": "Contact support",
          },
          {
            html: '<img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/firezone/firezone?label=Stars&amp;style=social" style="margin-top: 6px;" height="24">',
            href: "https://github.com/firezone/firezone",
            position: "right",
            "aria-label": "GitHub repository",
          },
        ],
      },
      footer: {
        style: "light",
        links: [
          {
            title: "Company",
            items: [
              {
                label: "Home",
                href: "/",
              },
              // {
              //   label: "Pricing",
              //   href: "/pricing",
              // },
            ],
          },
          {
            title: "Community",
            items: [
              {
                label: "Support Forums",
                href: "https://discourse.firez.one/?utm_source=docs.firezone.dev",
              },
              {
                label: "Slack",
                href: "https://join.slack.com/t/firezone-users/shared_invite/zt-19jd956j4-rWcCqiKMh~ikPGsUFbvZiA",
              },
              {
                label: "Github",
                href: "https://github.com/firezone/firezone?utm_source=docs.firezone.dev",
              },
              {
                label: "Twitter",
                href: "https://twitter.com/firezonehq?utm_source=docs.firezone.dev",
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Firezone, Inc.`,
      },
      prism: {
        theme: lightCodeTheme,
        darkTheme: darkCodeTheme,
        additionalLanguages: ["ruby", "elixir"],
      },
      algolia: {
        // The application ID provided by Algolia
        appId: "XXPZ9QVGFB",

        start_urls: ["https://www.firezone.dev/docs"],

        sitemap_urls: ["https://www.firezone.dev/sitemap.xml"],

        // Public API key: it is safe to commit it
        apiKey: "66664e8765e1645ea0b500acebb0b0c2",

        indexName: "firezone",

        // Optional: see doc section below
        // Requires more configuration and setup to work, so disabling. See
        // https://discourse.algolia.com/t/algolia-searchbar-is-not-working-with-docusaurus-v2/14659/2
        contextualSearch: true,

        // Optional: path for search page that enabled by default (`false` to disable it)
        searchPagePath: "search",

        //... other Algolia params
      },
      metadata: [
        {
          name: "keywords",
          content:
            "wireguard, vpn, firewall, remote access, network, documentation",
        },
      ],
    }),
};

module.exports = config;
