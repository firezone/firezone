// @ts-check

import eslint from "@eslint/js";
import { fixupConfigRules } from "@eslint/compat";
import tseslint from "typescript-eslint";
import reactplugin from "eslint-plugin-react";

export default tseslint.config({
  ignores: ["dist/**"],
  settings: {
    react: {
      version: "detect",
    },
  },
  extends: [
    eslint.configs.recommended,
    tseslint.configs.strict,
    fixupConfigRules(reactplugin.configs.flat.recommended),
  ],
});
