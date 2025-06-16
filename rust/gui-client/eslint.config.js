// @ts-check

import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import reactplugin from 'eslint-plugin-react'

export default tseslint.config({
  ignores: ["dist/**"],
  extends: [
    eslint.configs.recommended,
    tseslint.configs.strict,
    reactplugin.configs.flat.recommended,
  ]
});
