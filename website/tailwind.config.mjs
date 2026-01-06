import flowbite from "flowbite-react/plugin/tailwindcss";
import flowbiteTypography from "flowbite-typography";

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
    950: "#050505",
  },

  // gray: cool-gray
  "cool-gray": {
    50: "#F8FAFC",
    100: "#F1F5F9",
    200: "#E2E8F0",
    300: "#CBD5E1",
    400: "#94A3B8",
    500: "#64748B",
    600: "#475569",
    700: "#334155",
    800: "#1E293B",
    900: "#0F172A",
    950: "#020617",
  },
};

/** @type {import('tailwindcss').Config} */
const tailwindConfig = {
  darkMode: "class",
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
    "./node_modules/flowbite-react/dist/**/*.js",
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ["var(--font-source-sans-3)"],
      },
      boxShadow: {
        drop: "0px 16px 32px -4px rgba(12, 12, 13, 0.1), 0px 4px 4px -4px rgba(12, 12, 13, 0.05)",
        light:
          "0px 4px 8px 3px rgba(12, 12, 13, 0.08), 0px 1px 3px 0 rgba(12, 12, 13, 0.15)",
      },
      gridTemplateColumns: {
        // Simple 16 column grid
        16: "repeat(16, minmax(0, 1fr))",
      },
      typography: () => ({
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
            "--tw-format-quotes": firezoneColors["night-rider"][700],
            // "--tw-format-quote-borders": theme("colors.orange[300]"),
            // "--tw-format-captions": theme("colors.orange[700]"),
            // "--tw-format-code": firezoneColors["electric-violet"][800],
            // "--tw-format-code-bg": firezoneColors["electric-violet"][50],
            // "--tw-format-pre-code": firezoneColors["electric-violet"][800],
            // "--tw-format-pre-bg": firezoneColors["electric-violet"][50],
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
        grey: firezoneColors["cool-gray"],
      },
    },
  },
  plugins: [flowbite, flowbiteTypography],
};

export default tailwindConfig;
