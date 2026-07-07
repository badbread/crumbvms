// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docsSidebar: [
    {
      type: 'category',
      label: 'Getting Started',
      link: { type: 'doc', id: 'getting-started/what-is-crumb' },
      items: [
        'getting-started/what-is-crumb',
        'getting-started/requirements',
        'getting-started/install-docker-compose',
        'getting-started/install-with-ai-agent',
        'getting-started/first-run-wizard',
        'getting-started/upgrade-and-rollback',
      ],
    },
    {
      type: 'category',
      label: 'Configuration',
      link: { type: 'doc', id: 'configuration/index' },
      items: [
        'configuration/index',
        'configuration/environment-reference',
        'configuration/server-settings',
        'configuration/secrets',
        'configuration/tls',
        'configuration/backups',
        'configuration/hardware-decode',
      ],
    },
    {
      type: 'category',
      label: 'Cameras & Streams',
      link: { type: 'doc', id: 'cameras/index' },
      items: [
        'cameras/index',
        'cameras/adding-a-camera',
        'cameras/go2rtc-model',
        'cameras/onvif-ptz',
      ],
    },
    {
      type: 'category',
      label: 'Recording & Storage',
      link: { type: 'doc', id: 'recording/index' },
      items: [
        'recording/index',
        'recording/recording-modes',
        'recording/policies-and-groups',
        'recording/storage-tiers',
        'recording/bookmarks',
      ],
    },
    {
      type: 'category',
      label: 'Motion & Detection',
      link: { type: 'doc', id: 'motion/index' },
      items: [
        'motion/index',
        'motion/detectors',
        'motion/tuning',
        'motion/frigate-as-source',
      ],
    },
    {
      type: 'category',
      label: 'Clients',
      link: { type: 'doc', id: 'clients/index' },
      items: [
        'clients/index',
        'clients/android',
        'clients/windows-desktop',
        'clients/linux-desktop',
        'clients/macos',
        'clients/ios',
        'clients/web-console',
      ],
    },
    {
      type: 'category',
      label: 'Admin Console',
      link: { type: 'doc', id: 'admin-console/index' },
      items: [
        'admin-console/index',
      ],
    },
    {
      type: 'category',
      label: 'Notifications',
      link: { type: 'doc', id: 'notifications/index' },
      items: [
        'notifications/index',
      ],
    },
    {
      type: 'category',
      label: 'Integrations',
      link: { type: 'doc', id: 'integrations/index' },
      items: [
        'integrations/index',
        'integrations/frigate',
      ],
    },
    {
      type: 'category',
      label: 'Troubleshooting',
      link: { type: 'doc', id: 'troubleshooting/index' },
      items: [
        'troubleshooting/index',
      ],
    },
    {
      type: 'category',
      label: 'Contributing',
      link: { type: 'doc', id: 'contributing/index' },
      items: [
        'contributing/index',
        'contributing/security',
      ],
    },
    {
      type: 'category',
      label: 'Architecture',
      link: { type: 'doc', id: 'architecture/index' },
      items: [
        'architecture/index',
        'architecture/decisions',
        'architecture/recorder-correctness',
        'architecture/motion-recording',
      ],
    },
  ],
};

export default sidebars;
