// @ts-check
// CrumbVMS documentation site — docs.crumbvms.com
// No trackers: no gtag, no googleAnalytics, no external fonts/CDNs, no Algolia.
// Search is local (offline lunr index) via @easyops-cn/docusaurus-search-local.

import { themes as prismThemes } from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Crumb VMS',
  tagline: 'The operator layer for your cameras, self-hosted end to end.',
  favicon: 'img/favicon-32.png',

  future: {
    v4: true,
  },

  url: 'https://docs.crumbvms.com',
  baseUrl: '/',

  organizationName: 'badbread',
  projectName: 'crumb',

  onBrokenLinks: 'throw',

  // Docusaurus v4 moved onBrokenMarkdownLinks under markdown.hooks.
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.js',
          editUrl: 'https://github.com/badbread/crumbvms/edit/main/docs-site/docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themes: [
    [
      '@easyops-cn/docusaurus-search-local',
      /** @type {import('@easyops-cn/docusaurus-search-local').PluginOptions} */
      ({
        hashed: true,
        indexDocs: true,
        indexBlog: false,
        indexPages: true,
        docsRouteBasePath: '/',
        language: ['en'],
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      image: 'img/og-card.png',
      colorMode: {
        defaultMode: 'dark',
        respectPrefersColorScheme: false,
      },
      navbar: {
        title: 'Crumb VMS',
        logo: {
          alt: 'Crumb VMS',
          src: 'img/icon-mark.svg',
          srcDark: 'img/icon-mark-reversed.svg',
        },
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'docsSidebar',
            position: 'left',
            label: 'Docs',
          },
          {
            to: '/responsible-use',
            label: 'Responsible use',
            position: 'left',
          },
          {
            href: 'https://crumbvms.com',
            label: 'crumbvms.com',
            position: 'right',
          },
          {
            href: 'https://github.com/badbread/crumbvms',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              { label: 'Getting Started', to: '/getting-started/what-is-crumb' },
              { label: 'Configuration', to: '/configuration/environment-reference' },
              { label: 'Clients', to: '/clients/' },
              { label: 'Troubleshooting', to: '/troubleshooting/' },
            ],
          },
          {
            title: 'Project',
            items: [
              { label: 'crumbvms.com', href: 'https://crumbvms.com' },
              { label: 'GitHub', href: 'https://github.com/badbread/crumbvms' },
              { label: 'Contributing', to: '/contributing/' },
              { label: 'Security reporting', to: '/contributing/security' },
            ],
          },
          {
            title: 'Legal',
            items: [
              { label: 'Responsible & lawful use', to: '/responsible-use' },
              { label: 'License: AGPL-3.0-or-later', href: 'https://github.com/badbread/crumbvms/blob/main/LICENSE' },
            ],
          },
        ],
        copyright: `Crumb VMS is free and open source software, AGPL-3.0-or-later. Follow the trail.`,
      },
      prism: {
        theme: prismThemes.oneLight,
        darkTheme: prismThemes.oneDark,
        additionalLanguages: ['bash', 'toml', 'yaml', 'sql', 'json'],
      },
      metadata: [
        { name: 'referrer', content: 'no-referrer' },
      ],
    }),
};

export default config;
