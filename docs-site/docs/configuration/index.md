---
title: Configuration
sidebar_label: Overview
slug: /configuration/
---

# Configuration

Crumb is configured two ways, and they're layered on purpose.

**Environment variables** (`.env`, read at container startup) set defaults
and secrets: database credentials, the JWT signing secret, storage paths,
optional integrations. Most of these are written for you by
`scripts/setup-env.sh` and rarely need touching again.

**Admin console settings** (stored in Postgres, editable at any time from
`/admin`) cover everything an operator changes routinely: the server's
advertised address, storage policies, per-camera settings, notification
channels, users and roles. Where a setting exists in both places, for
example the address native clients use to reach streaming, the console
value wins whenever it's set; the environment value is only a fallback for
a fresh install with nothing configured yet. Console code only ever writes
the specific field it's editing, so an admin action never silently
clobbers an unrelated setting.

This section covers the environment side: what's in `.env`, how secrets
are generated and rotated, backups, and TLS. For the console side, see
[Admin Console](/admin-console/).

## In this section

- [Environment reference](/configuration/environment-reference), every
  `.env` key, grouped by area.
- [Secrets](/configuration/secrets), how they're generated, where they
  live, and how to rotate them.
- [Backups](/configuration/backups), the built-in nightly database backup
  and how to get a copy off-host.
- [TLS](/configuration/tls), the bundled HTTPS reverse proxy and what its
  certificate warning means.
- [Hardware decode](/configuration/hardware-decode), enabling VAAPI or
  NVDEC for motion analysis.
- [Server settings](/configuration/server-settings), the console-side
  settings that override environment defaults.
