---
title: Security reporting
sidebar_label: Security reporting
slug: /contributing/security
---

# Security reporting

Crumb records security cameras. Footage and the credentials that reach
your cameras are among the most sensitive data a self-hosted system can
hold, so vulnerability reports are taken seriously and should be made
privately.

## Reporting a vulnerability

**Please do not open a public issue for a security vulnerability.** A
public issue tips off attackers before a fix exists. Instead, use the
repository's private vulnerability reporting feature (on GitHub: Security
→ Report a vulnerability), which keeps the report visible only to the
maintainer until it's resolved.

When you report, include as much of the following as you can: the
affected component (server API, recorder, or a specific client), the
version or commit you're running and how it's deployed, a description of
the issue and its impact, steps to reproduce or a minimal test case, and
any suggested remediation.

## What's in scope

The server API, the recorder and shared backend, every client (desktop,
Android, iOS, and the web admin console), and the Docker Compose
deployment, first-run setup flow, and authentication/token model.

## What's out of scope

Vulnerabilities in third-party components Crumb doesn't author, an
embedded object-detection integration, the restreaming layer, FFmpeg, the
native video library, PostgreSQL, and other bundled or depended-upon
software, should be reported to their upstream projects instead. If a
Crumb-side change could still mitigate an upstream issue, it's still worth
reporting here too, just note the root cause is upstream.

## Response expectations

This is a one-maintainer side project, so please be patient, but you can
expect an acknowledgement within about five business days, an initial
assessment after that, and coordinated disclosure, timing agreed with you
and credit in the fix or advisory unless you'd rather stay anonymous.

## Secure by default, before you deploy

Most real-world exposure comes from deployment, not code:

- Never expose a Crumb instance directly to the public internet. The
  default install is LAN-only, and it should stay that way.
- For remote access, use a private overlay like Tailscale or WireGuard
  rather than port-forwarding.
- If you must reach it beyond the LAN, put TLS in front of it and set a
  strong admin password first, both are preconditions, not
  nice-to-haves.
- Use the generated secrets from the setup script; never invent or reuse
  weak ones. See [Secrets](/configuration/secrets).

Your instance holds your footage. Treat it accordingly.
