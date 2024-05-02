const flowbite = require("flowbite-react/tailwind");

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
  // neutral: night-rider
  "night-rider": {
    50: "#fcfcfc",
    100: "#f8f7f7",
    200: "#ebebea",
    300: "#dfdedd",
    400: "#c7c4c2",
    500: "#a7a3a0",
    600: "#90867f",
    700: "#766a60",
    800: "#4c3e33",
    900: "#1b140e",
  },
};

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    flowbite.content(),
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      typography: ({ theme }) => ({
        firezone: {
          css: {
            "--tw-format-body": firezoneColors["night-rider"][800],
            "--tw-format-headings": firezoneColors["night-rider"][800],
            "--tw-format-lead": firezoneColors["night-rider"][800],
            "--tw-format-links": firezoneColors["electric-violet"][500],
            "--tw-format-bold": firezoneColors["night-rider"][800],
            // "--tw-format-counters": theme("colors.orange[500]"),
            // "--tw-format-bullets": theme("colors.orange[500]"),
            // "--tw-format-hr": theme("colors.orange[200]"),
            // "--tw-format-quotes": theme("colors.orange[900]"),
            // "--tw-format-quote-borders": theme("colors.orange[300]"),
            // "--tw-format-captions": theme("colors.orange[700]"),
            "--tw-format-code": firezoneColors["electric-violet"][800],
            "--tw-format-code-bg": firezoneColors["electric-violet"][50],
            "--tw-format-pre-code": firezoneColors["electric-violet"][800],
            "--tw-format-pre-bg": firezoneColors["electric-violet"][50],
            // "--tw-format-th-borders": theme("colors.orange[300]"),
            // "--tw-format-td-borders": theme("colors.orange[200]"),
            // "--tw-format-th-bg": theme("colors.orange[50]"),
            // "--tw-format-invert-body": theme("colors.orange[200]"),
            // "--tw-format-invert-headings": theme("colors.white"),
            // "--tw-format-invert-lead": theme("colors.orange[300]"),
            // "--tw-format-invert-links": theme("colors.white"),
            // "--tw-format-invert-bold": theme("colors.white"),
            // "--tw-format-invert-counters": theme("colors.orange[400]"),
            // "--tw-format-invert-bullets": theme("colors.orange[600]"),
            // "--tw-format-invert-hr": theme("colors.orange[700]"),
            // "--tw-format-invert-quotes": theme("colors.pink[100]"),
            // "--tw-format-invert-quote-borders": theme("colors.orange[700]"),
            // "--tw-format-invert-captions": theme("colors.orange[400]"),
            // "--tw-format-invert-code": theme("colors.white"),
            // "--tw-format-invert-pre-code": theme("colors.orange[300]"),
            // "--tw-format-invert-pre-bg": "rgb(0 0 0 / 50%)",
            // "--tw-format-invert-th-borders": theme("colors.orange[600]"),
            // "--tw-format-invert-td-borders": theme("colors.orange[700]"),
            // "--tw-format-invert-th-bg": theme("colors.orange[700]"),
          },
        },
      }),
      colors: {
        primary: firezoneColors["heat-wave"],
        accent: firezoneColors["electric-violet"],
        neutral: firezoneColors["night-rider"],
      },
    },
  },
  plugins: [flowbite.plugin(), require("flowbite-typography")],
};
