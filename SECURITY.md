# Security Policy

CrumbVMS records security cameras. Footage and the credentials that reach
your cameras are among the most sensitive data a self-hosted system can hold,
so we take vulnerability reports seriously and ask you to report them
privately.

## Reporting a vulnerability

**Please do not open a public GitHub issue for a security vulnerability.** A
public issue tips off attackers before a fix exists.

Instead, **use GitHub private vulnerability reporting**: on the repository, go
to **Security → Report a vulnerability** and file a private advisory. This keeps
the report visible only to the maintainer until it's resolved.

> **Maintainer setup:** enable **private vulnerability reporting** in the
> repository's **Settings → Security** before the first invite goes out, the
> GitHub advisory path above depends on it.

When you report, please include as much of the following as you can:

- the affected component (server API, recorder, or a specific client);
- the version / commit you're running and how it's deployed (Docker Compose,
  which client build);
- a description of the issue and its impact;
- steps to reproduce, a proof of concept, or a minimal test case;
- any suggested remediation.

## What's in scope

- The **server API** (`services/api`).
- The **recorder** (`services/recorder`) and shared backend (`services/common`).
- The **clients**: desktop (`apps/desktop`), Android (`apps/android`), iOS
  (`apps/ios`), and the web admin console (served by the API at `/admin`).
- The Docker Compose deployment, first-run setup flow, and the auth/token model.

## What's out of scope

Vulnerabilities in **third-party components** we don't author should be
reported to their upstream projects, not here:

- **Frigate**, bring-your-own object detection.
- **go2rtc**, stream restreaming / WebRTC.
- **FFmpeg**, **mpv / libmpv**, **PostgreSQL**, **Eclipse Mosquitto**, and other
  bundled or depended-upon software (see [NOTICE](NOTICE) for the list and
  upstream links).

If a CrumbVMS-side change could mitigate an upstream issue, we're still glad to
hear about it, just note that the root cause is upstream.

## Response expectations

This is a one-maintainer side project, so please be patient, but you can expect:

- an **acknowledgement within about 5 business days**;
- an initial assessment (severity, whether it reproduces) after that;
- coordinated disclosure, we'll agree on timing with you and credit you in the
  fix/advisory unless you'd rather stay anonymous.

## Secure by default, before you deploy

Most real-world exposure comes from deployment, not code. CrumbVMS is designed to
be **secure by default**, and these rules (mirrored from
[docs/AI-INSTALL.md](docs/AI-INSTALL.md)) matter as much as any patch:

- **Never expose a CrumbVMS instance directly to the public internet.** The
  default install is **LAN-only** and it should stay that way.
- For remote access, use a private overlay (Tailscale / WireGuard) rather than
  port-forwarding.
- If you *must* reach it beyond the LAN, put **TLS** (a reverse proxy with a
  real certificate) in front of it **and** set a **strong admin password**
  first, both are preconditions, not nice-to-haves.
- Use the generated secrets from `scripts/setup-env.sh`; never invent or reuse
  weak ones.

Your instance holds *your* footage. Treat it accordingly.
