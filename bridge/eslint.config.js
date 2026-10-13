import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/", "node_modules/", "test/fake-agent.mjs"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
);
