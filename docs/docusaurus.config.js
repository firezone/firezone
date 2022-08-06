// @ts-check
// Note: type annotations allow type checking and IDEs autocompletion

const lightCodeTheme = require("prism-react-renderer/themes/github");
const darkCodeTheme = require("prism-react-renderer/themes/dracula");

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "Firezone",
  tagline: "Open-source VPN server and Linux firewall built on WireGuard®",
  url: "https://docs.firezone.dev",
  baseUrl: "/",
  onBrokenLinks: "throw",
  onBrokenMarkdownLinks: "warn",
  favicon: "img/favicon.ico",

  // GitHub pages deployment config.
  // If you aren't using GitHub pages, you don't need these.
  organizationName: "firezone", // Usually your GitHub org/user name.
  projectName: "firezone", // Usually your repo name.
  trailingSlash: false,

  // Even if you don't use internalization, you can use this field to set useful
  // metadata like html lang. For example, if your site is Chinese, you may want
  // to replace "en" with "zh-Hans".
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
      src: '/js/posthog.js',
      async: true
    }
  ],

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          routeBasePath: "/",
          sidebarPath: require.resolve("./sidebars.js"),
          editUrl: "https://github.com/firezone/firezone",
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
        title: "Documentation",
        logo: {
          alt: "Firezone",
          src: "img/logo.svg",
        },
        items: [
          {
            href: "https://discourse.firez.one/",
            label: "Ask a Question",
            position: "right",
            "aria-label": "GitHub repository",
          },
          {
            href: "https://e04kusl9oz5.typeform.com/to/gzzaZZ52#source=docsheader",
            label: "Join the Beta",
            position: "right",
            "aria-label": "GitHub repository",
          },
          {
            href: "https://github.com/firezone/firezone",
            className: 'header-github-link',
            position: "right",
            'aria-label': 'GitHub repository',
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
                label: "Homepage",
                href: "https://www.firezone.dev/",
              },
              {
                label: "Pricing",
                href: "https://www.firezone.dev/pricing",
              },
              {
                label: "About",
                href: "https://www.firezone.dev/about",
              },
              {
                label: "Join the Beta",
                href: "https://e04kusl9oz5.typeform.com/to/gzzaZZ52#source=docsfooter",
              },
            ],
          },
          {
            title: "Community",
            items: [
              {
                label: "Support Forums",
                href: "https://discourse.firez.one/",
              },
              {
                label: "Slack",
                href: "https://www.firezone.dev/slack",
              },
              {
                label: "Github",
                href: "https://github.com/firezone/firezone",
              },
              {
                label: "Twitter",
                href: "https://twitter.com/firezonehq",
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Firezone, Inc.`,
      },
      prism: {
        theme: lightCodeTheme,
        darkTheme: darkCodeTheme,
        additionalLanguages: ['ruby', 'elixir']
      },
      algolia: {
        // The application ID provided by Algolia
        appId: "XXPZ9QVGFB",

        // Public API key: it is safe to commit it
        apiKey: "66664e8765e1645ea0b500acebb0b0c2",

        indexName: "firezone",

        // Optional: see doc section below
        // Requires more configuration and setup to work, so disabling. See
        // https://discourse.algolia.com/t/algolia-searchbar-is-not-working-with-docusaurus-v2/14659/2
        contextualSearch: false,

        // Optional: path for search page that enabled by default (`false` to disable it)
        searchPagePath: "search",

        //... other Algolia params
      },
      themeConfig: {
        metadata: [{name: 'keywords', content: 'wireguard, vpn, firewall, remote, network, documentation'}],
      },
    }),
};

module.exports = config;
