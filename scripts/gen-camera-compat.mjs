#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// Crumb docs site — generate the Camera Compatibility page from structured data.
//
// Source of truth: data/camera-compatibility.json (human-curated, PR-only, no
// telemetry). This script renders it into
// docs-site/docs/cameras/compatibility.md with a "do not edit here" banner, the
// same generate-then-commit model as scripts/sync-arch-docs.mjs. The JSON stays
// the single source so the page can never drift from it, and so a future
// in-app "known quirks for this model" hint can read the very same file
// (serde_json on the Rust side) instead of re-deriving anything.
//
// Zero dependencies (Node built-ins only) so CI runs it before the docusaurus
// build with nothing but actions/setup-node. See .github/workflows/docs.yml.
//
// Usage:
//   node scripts/gen-camera-compat.mjs
// ─────────────────────────────────────────────────────────────────────────────

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..');
const SOURCE = join(REPO_ROOT, 'data', 'camera-compatibility.json');
const DEST = join(REPO_ROOT, 'docs-site', 'docs', 'cameras', 'compatibility.md');
const REPO_URL = 'https://github.com/badbread/crumbvms';

// Order + human labels for the support matrix (drives every rendered row).
const SUPPORT_ROWS = [
  ['recording', 'Recording'],
  ['desktop_live', 'Desktop live'],
  ['web_live', 'Web live'],
  ['android_live', 'Android live'],
  ['ios_live', 'iOS live'],
  ['playback', 'Playback'],
  ['onvif', 'ONVIF'],
  ['ptz', 'PTZ'],
];

const STATUS_ICON = { yes: '✅', partial: '⚠️', no: '❌', unknown: '❓' };

function icon(status) {
  return `${STATUS_ICON[status] ?? '❓'} ${status ?? 'unknown'}`;
}

// The page is rendered through MDX; `<` and `{` are markup there. Entries are
// asked (data/README.md) to avoid them, but be defensive so one stray char in a
// contributed PR can't break the whole docs build.
function safe(text) {
  return String(text ?? '').replace(/</g, '&lt;').replace(/\{/g, '&#123;');
}

function title(cam) {
  const model = cam.model && cam.model.trim() ? cam.model.trim() : '(model to be confirmed)';
  return `${cam.make} ${model}`;
}

function anchorId(cam) {
  return title(cam)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/(^-|-$)/g, '');
}

function headlineQuirk(cam) {
  if (!cam.quirks || cam.quirks.length === 0) return 'None reported';
  return cam.quirks.map((q) => q.summary).join('; ');
}

function renderCameraDetail(cam) {
  const lines = [];
  lines.push(`## ${safe(title(cam))} {#${anchorId(cam)}}`);
  lines.push('');
  const meta = [];
  if (cam.category) meta.push(`**Type:** ${safe(cam.category)}`);
  if (cam.aka && cam.aka.length) meta.push(`**Also sold as:** ${cam.aka.map(safe).join(', ')}`);
  if (!cam.model || !cam.model.trim()) meta.push('**Model:** _needs confirmation_');
  if (meta.length) {
    lines.push(meta.join(' · '));
    lines.push('');
  }

  // Streams
  lines.push('**Streams**');
  lines.push('');
  lines.push('| Stream | Codec | Notes |');
  lines.push('| --- | --- | --- |');
  for (const key of ['main', 'sub']) {
    const s = cam.streams?.[key];
    if (!s) continue;
    lines.push(`| ${key === 'main' ? 'Main' : 'Sub'} | ${safe(s.codec)} | ${safe(s.notes ?? '')} |`);
  }
  lines.push('');

  // Support matrix
  lines.push('**Support**');
  lines.push('');
  lines.push('| Capability | Status |');
  lines.push('| --- | --- |');
  for (const [key, label] of SUPPORT_ROWS) {
    const v = cam.support?.[key];
    if (v === undefined) continue;
    lines.push(`| ${label} | ${icon(v)} |`);
  }
  lines.push('');

  // Quirks
  if (cam.quirks && cam.quirks.length) {
    lines.push('**Quirks & fixes**');
    lines.push('');
    for (const q of cam.quirks) {
      const affects = q.affects && q.affects.length ? ` _(affects: ${q.affects.map(safe).join(', ')})_` : '';
      lines.push(`- **${safe(q.summary)}**${affects}`);
      if (q.detail) lines.push(`  - ${safe(q.detail)}`);
      if (q.fix) lines.push(`  - **Fix:** ${safe(q.fix)}`);
    }
    lines.push('');
  }

  // Recommended settings
  if (cam.recommended_settings && cam.recommended_settings.length) {
    lines.push('**Recommended settings**');
    lines.push('');
    for (const r of cam.recommended_settings) lines.push(`- ${safe(r)}`);
    lines.push('');
  }

  // Tested + references
  if (cam.tested) {
    const t = cam.tested;
    const bits = [];
    if (t.by) bits.push(`by ${safe(t.by)}`);
    if (t.date) bits.push(safe(t.date));
    if (t.method) bits.push(safe(t.method));
    lines.push(`_Tested ${bits.join(' · ')}._`);
    lines.push('');
  }
  if (cam.references && cam.references.length) {
    lines.push('References: ' + cam.references.map((u) => `[${safe(u)}](${u})`).join(' · '));
    lines.push('');
  }
  return lines.join('\n');
}

function render(data) {
  const cams = [...(data.cameras ?? [])].sort((a, b) =>
    title(a).localeCompare(title(b)),
  );

  const out = [];
  out.push('---');
  out.push('title: Camera compatibility');
  out.push('sidebar_label: Camera compatibility');
  out.push('description: Community-tested cameras, known quirks, and the fixes that work with Crumb.');
  out.push('---');
  out.push('');
  out.push('{/* GENERATED FILE — do not edit here. */}');
  out.push('{/* Source: data/camera-compatibility.json — edit that and run `node scripts/gen-camera-compat.mjs`. */}');
  out.push('');
  out.push('# Camera compatibility');
  out.push('');
  out.push(
    'A community-maintained list of cameras people have run with Crumb: what ' +
      'works, the quirks worth knowing, and the fixes. It is curated by hand and ' +
      'contributed by pull request only, Crumb never collects anything about ' +
      'your cameras (no telemetry, no phone-home).',
  );
  out.push('');
  out.push(
    `**Add your camera:** edit [\`data/camera-compatibility.json\`](${REPO_URL}/blob/main/data/camera-compatibility.json), ` +
      `run the generator, and open a PR. See [\`data/README.md\`](${REPO_URL}/blob/main/data/README.md) for the schema.`,
  );
  out.push('');
  out.push('Most cameras just work; this page exists for the ones with a wrinkle. An empty list under a camera means no quirks were reported.');
  out.push('');

  // Legend
  out.push('**Status:** ✅ works · ⚠️ works with a caveat · ❌ not working · ❓ not tested');
  out.push('');

  // Summary table
  out.push('## Tested cameras');
  out.push('');
  out.push('| Camera | Type | Main / Sub | Android live | Headline quirk |');
  out.push('| --- | --- | --- | --- | --- |');
  for (const cam of cams) {
    const main = cam.streams?.main?.codec ?? '?';
    const sub = cam.streams?.sub?.codec ?? '?';
    const android = STATUS_ICON[cam.support?.android_live] ?? '❓';
    out.push(
      `| [${safe(title(cam))}](#${anchorId(cam)}) | ${safe(cam.category ?? '')} | ${safe(main)} / ${safe(sub)} | ${android} | ${safe(headlineQuirk(cam))} |`,
    );
  }
  out.push('');

  // Details
  for (const cam of cams) {
    out.push(renderCameraDetail(cam));
  }

  return out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

function main() {
  const data = JSON.parse(readFileSync(SOURCE, 'utf8'));
  mkdirSync(dirname(DEST), { recursive: true });
  writeFileSync(DEST, render(data), 'utf8');
  const n = (data.cameras ?? []).length;
  console.log(`gen-camera-compat: wrote ${DEST} (${n} camera${n === 1 ? '' : 's'}).`);
}

main();
