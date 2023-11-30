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
    "node_modules/flowbite-react/**/*.{js,ts,jsx,tsx}",
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      typography: {
        DEFAULT: {
          css: {
            color: firezoneColors["night-rider"][800],
            a: {
              color: firezoneColors["electric-violet"][500],
            },
          },
        },
      },
      colors: {
        primary: firezoneColors["heat-wave"],
        accent: firezoneColors["electric-violet"],
        neutral: firezoneColors["night-rider"],
      },
    },
  },
  plugins: [require("flowbite/plugin"), require("flowbite-typography")],
};
