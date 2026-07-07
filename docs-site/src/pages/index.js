import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';

import styles from './index.module.css';

const FEATURES = [
  {
    title: 'Investigate',
    body: 'A frame-level, scrubbable timeline across every camera, including 4K H.265 with no server-side transcode. Jump to the next or previous motion event, and digitally zoom into a clip.',
  },
  {
    title: 'Watch',
    body: 'A multi-camera live wall with saveable, per-device layouts: carousels, PTZ tiles, clocks, and on-video pan/tilt/zoom control for cameras that support it.',
  },
  {
    title: 'Keep',
    body: 'A Rust recorder with a Postgres segment index as the single source of truth. Motion mode buffers in RAM and only persists on an actual event, idle time is never written to disk.',
  },
  {
    title: 'Control',
    body: 'A guided first-run wizard, generated secrets, and a LAN-only default. Custom roles with per-camera and per-group access, batch export to MP4 or an encrypted archive.',
  },
];

function HomepageHeader() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <header className={clsx('hero hero--primary', styles.heroBanner)}>
      <div className="container">
        <Heading as="h1" className="hero__title">
          {siteConfig.title}
        </Heading>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <p className={styles.heroSub}>
          A serious video management system for your own cameras. The kind of
          operator experience that used to only come with commercial,
          installer-grade platforms, in something you run yourself. Bring your
          own object detector, or none at all.
        </p>
        <div className={styles.buttons}>
          <Link className="button button--primary button--lg" to="/getting-started/what-is-crumb">
            What is Crumb VMS
          </Link>
          <Link
            className={clsx('button button--outline button--lg', styles.secondaryButton)}
            to="/getting-started/install-docker-compose">
            Install with Docker Compose
          </Link>
        </div>
      </div>
    </header>
  );
}

function Feature({ title, body }) {
  return (
    <div className={clsx('col col--6', styles.feature)}>
      <div className={styles.featureCard}>
        <Heading as="h3">{title}</Heading>
        <p>{body}</p>
      </div>
    </div>
  );
}

export default function Home() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout
      title={siteConfig.title}
      description="Documentation for Crumb VMS, a self-hosted video management system for recording and reviewing your own cameras.">
      <HomepageHeader />
      <main>
        <section className={styles.features}>
          <div className="container">
            <div className="row">
              {FEATURES.map((f) => (
                <Feature key={f.title} {...f} />
              ))}
            </div>
          </div>
        </section>
        <section className={styles.ctaSection}>
          <div className="container">
            <Heading as="h2">Where to start</Heading>
            <ul>
              <li>
                New to Crumb? Start with{' '}
                <Link to="/getting-started/what-is-crumb">What is Crumb VMS</Link>.
              </li>
              <li>
                Ready to install?{' '}
                <Link to="/getting-started/install-docker-compose">Install with Docker Compose</Link>{' '}
                or{' '}
                <Link to="/getting-started/install-with-ai-agent">install with an AI agent</Link>.
              </li>
              <li>
                Setting up a client?{' '}
                <Link to="/clients/">See the Clients section</Link>.
              </li>
              <li>
                Before you rely on Crumb for anything, read{' '}
                <Link to="/responsible-use">Responsible &amp; lawful use</Link>.
              </li>
            </ul>
          </div>
        </section>
      </main>
    </Layout>
  );
}
