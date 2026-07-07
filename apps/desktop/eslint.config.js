// Flat ESLint config for the desktop frontend (review A2). The frontend is one
// large no-bundler ES module on WebView2, so nothing mechanically caught typos,
// references to renamed globals, or dead vars until they failed at runtime in
// whatever view hit that path. This is the cheapest guard: no-undef +
// no-unused-vars only — no style churn.
import globals from 'globals';

export default [
  {
    files: ['src/**/*.js'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'module',
      globals: {
        ...globals.browser,
        // Tauri 2 exposes these on window.__TAURI__ (withGlobalTauri).
        __TAURI__: 'readonly',
      },
    },
    rules: {
      // The load-bearing rule: catch references to undefined / renamed symbols.
      // app.js forward-references its own module-scope functions/consts (all in
      // one file), which flat-config module scope resolves correctly.
      'no-undef': 'error',
      // Dead/forgotten vars. Underscore-prefixed are intentional throwaways.
      'no-unused-vars': ['warn', { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrors: 'none' }],
    },
  },
];
