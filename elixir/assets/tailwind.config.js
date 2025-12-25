// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin");
const fs = require("fs");
const path = require("path");
const defaultTheme = require("tailwindcss/defaultTheme");
const colors = require("tailwindcss/colors");

const firezoneColors = {
  // See our brand palette in Figma.
  // These have been reversed to match Tailwind's default order.

  // primary: orange
  "heat-wave": {
    50: "#fff9f5",
    100: "#fff1e5",
    200: "#ffddc2",
    300: "#ffbc85",
    400: "#ff9a47",
    450: "#ff7300",
    500: "#ff7605",
    600: "#c25700",
    700: "#7f3900",
    800: "#5c2900",
    900: "#331700",
  },
  // accent: violet
  "electric-violet": {
    50: "#f8f5ff",
    100: "#ece5ff",
    200: "#d2c2ff",
    300: "#a585ff",
    400: "#7847ff",
    450: "#5e00d6",
    500: "#4805ff",
    600: "#3400c2",
    700: "#37007f",
    800: "#28005c",
    900: "#160033",
  },
  // neutral: chicago
  chicago: {
    50: "#f6f6f6",
    100: "#e7e7e7",
    200: "#d1d1d1",
    300: "#b0b0b0",
    400: "#888888",
    500: "#6d6d6d",
    600: "#575757",
    700: "#4f4f4f",
    800: "#454545",
    900: "#3d3d3d",
    950: "#262626",
  },
};

module.exports = {
  // Use "media" to synchronize dark mode with the OS, "class" to require manual toggle
  darkMode: "class",
  content: [
    "./node_modules/flowbite/**/*.js",
    "./js/**/*.js",
    "../lib/portal_web.ex",
    "../lib/portal_web/**/*.*ex",
  ],
  theme: {
    fontFamily: {
      sans: ['"Source Sans 3 Variable"', ...defaultTheme.fontFamily.sans],
    },
    extend: {
      colors: {
        brand: "#FD4F00",
        primary: firezoneColors["heat-wave"],
        accent: firezoneColors["electric-violet"],
        neutral: firezoneColors["chicago"],
      },
    },
  },
  plugins: [
    require("flowbite/plugin")({
      charts: true,
    }),
    require("@tailwindcss/forms"),
    plugin(({ addVariant }) =>
      addVariant("phx-click-loading", [
        ".phx-click-loading&",
        ".phx-click-loading &",
      ])
    ),
    plugin(({ addVariant }) =>
      addVariant("phx-submit-loading", [
        ".phx-submit-loading&",
        ".phx-submit-loading &",
      ])
    ),
    plugin(({ addVariant }) =>
      addVariant("phx-change-loading", [
        ".phx-change-loading&",
        ".phx-change-loading &",
      ])
    ),

    // Embeds Hero Icons (https://heroicons.com) into your app.css bundle
    // See your `CoreComponents.icon/1` for more information.
    //
    plugin(function ({ matchComponents, theme }) {
      let iconsDir = path.join(__dirname, "./vendor/heroicons/optimized");
      let values = {};
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
      ];
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).map((file) => {
          let name = path.basename(file, ".svg") + suffix;
          values[name] = { name, fullPath: path.join(iconsDir, dir, file) };
        });
      });
      matchComponents(
        {
          hero: ({ name, fullPath }) => {
            let content = fs
              .readFileSync(fullPath)
              .toString()
              .replace(/\r?\n|\r/g, "");
            return {
              [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
              "-webkit-mask": `var(--hero-${name})`,
              mask: `var(--hero-${name})`,
              "background-color": "currentColor",
              "vertical-align": "middle",
              display: "inline-block",
              width: theme("spacing.5"),
              height: theme("spacing.5"),
            };
          },
        },
        { values }
      );
    }),
  ],
};
