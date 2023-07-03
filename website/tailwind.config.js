const colors = require("tailwindcss/colors");

const firezoneColors = {
  // See our brand palette in Figma

  // primary: orange
  "heat-wave": {
    50: "#fff9f5",
    100: "#fff1e5",
    200: "#ffbc85",
    300: "#ff9a47",
    400: "#d2bab0",
    500: "#bfa094",
    600: "#a18072",
    700: "#977669",
    800: "#846358",
    900: "#43302b",
  },
  // accent: violet
  "electric-violet": {
    50: "#f8f5ff",
    100: "#ece5ff",
    200: "#d2c2ff",
    300: "#a585ff",
    400: "#7847ff",
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
  // TODO: Classes need to be updated for these to make sense.
  // theme: {
  //   colors: {
  //     primary: firezoneColors["heat-wave"],
  //     accent: firezoneColors["electric-violet"],
  //     neutral: firezoneColors["night-rider"],
  //   },
  // },
  plugins: [require("flowbite/plugin"), require("flowbite-typography")],
};
