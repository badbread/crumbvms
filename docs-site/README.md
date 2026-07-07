# docs.crumbvms.com

Public documentation site for Crumb VMS, built with
[Docusaurus](https://docusaurus.io/) v3, docs-only mode, local (offline)
search via `@easyops-cn/docusaurus-search-local`. No trackers, no external
fonts or CDNs, no third-party search service, consistent with the parent
project's no-telemetry stance. The docs-site generator choice and deploy
model are recorded in `docs/DECISIONS.md` at the repository root.

## Structure

```
docs-site/
  docusaurus.config.js
  sidebars.js
  docs/                 # the published content
    getting-started/ configuration/ cameras/ recording/ motion/
    clients/ admin-console/ notifications/ integrations/
    troubleshooting/ contributing/ architecture/
    responsible-use.md   # standalone page, linked from the navbar
  src/                  # homepage + theme CSS
  static/               # favicons, brand marks, og-card
```

## The Architecture section is generated, not authored here

`docs/architecture/decisions.md`, `recorder-correctness.md`, and
`motion-recording.md` are copied
automatically from the repository's `docs/` directory by
`../scripts/sync-arch-docs.mjs`, with a banner noting where to actually
make edits. They're gitignored in this directory (see `.gitignore`) so
they're always regenerated fresh at build time and can't drift stale in
git relative to their real source. Only `docs/architecture/index.md` (this
section's hand-written landing page) is committed normally.

Always run the sync script before building:

```bash
node ../scripts/sync-arch-docs.mjs
```

(CI does this automatically, see `.github/workflows/docs.yml` at the repo
root.)

## Local development

```bash
npm ci
node ../scripts/sync-arch-docs.mjs
npm run build
npm run serve
```

`npm run start` also works for live-reloading local development, though the
Architecture pages won't appear until you've run the sync script at least
once.

## Self-hosting

The build output (`npm run build`) is a fully static `build/` directory.
Anyone, including an air-gapped operator, can run the same two commands
above and serve `build/` with any web server, no Node runtime needed at
serve time. See `Dockerfile` and `nginx.conf` in this directory for the
containerized version of that same pattern.

## Deploying

See the repository root `AGENTS.md` and the docs-site entry in
`docs/DECISIONS.md` for the production deploy target and process. In short:
this directory's
`Dockerfile` builds the static site and serves it with `nginx:alpine` on
port 3000, matching the same pattern the crumbvms.com marketing site uses.
