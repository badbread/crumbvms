---
title: Install with an AI agent
sidebar_label: Install with an AI agent
slug: /getting-started/install-with-ai-agent
---

# Install with an AI agent

Crumb ships an agent-runnable install runbook in the repository at
[`docs/AI-INSTALL.md`](https://github.com/badbread/crumbvms/blob/main/docs/AI-INSTALL.md).
If you're using a tool like Claude Code, point it at a clone of the
repository on the host where Crumb will run and ask it to follow that
file. It is not a replacement for the manual path, it's the same steps,
written so an agent can execute them safely with a Verify check after
each one.

## Why a separate runbook

The manual path in
[Install with Docker Compose](/getting-started/install-docker-compose) is
written for a person reading along. The agent runbook encodes the same
steps as explicit, checkable instructions: generate secrets with the
provided script rather than inventing them, confirm a health check before
moving to the next step, and stop and report rather than guessing forward
when something fails.

## Ground rules the runbook enforces

These apply whether a person or an agent is doing the install, and are
worth knowing either way:

- **Secure by default, LAN-only.** The default install never exposes Crumb
  to the public internet. An agent following the runbook will not open WAN
  firewall ports, set up port-forwarding, or stand up a public reverse
  proxy on its own initiative, even if asked to "make it work from
  anywhere," without first confirming TLS and a strong admin password are
  in place.
- **Never invents or prints secrets.** Secrets come from
  `scripts/setup-env.sh`, which generates strong random values. An agent
  should never hardcode a password or secret, and should avoid echoing
  them into chat history if you ask for the admin password back; the
  script's `--print` flag is the intended path for that.
- **Confirms before privileged or destructive actions.** Installing system
  packages, changing firewall rules, deleting data, or overwriting an
  existing `.env` are all things the runbook asks the agent to show you and
  confirm first, not run silently.
- **One step at a time, verified.** Crumb is a recorder people rely on;
  the runbook is written to prefer correctness over speed, with an explicit
  Verify check after every step before moving on.

## What the runbook covers

The same ground as the manual path, plus the machinery for a fully
hands-off setup: host prerequisites, secret generation, choosing a storage
path, optionally enabling hardware decode, bringing up the stack, and then
first-run configuration. For that last step, the runbook documents **two
paths**: handing off to the web setup wizard (the simplest), or driving
the entire first-run flow through the REST API for a fully scripted,
headless install, including camera discovery, adding cameras in bulk, and
setting up notifications and additional users without opening a browser.

It also covers what a fresh install needs after the first boot: confirming
the nightly database backup is landing somewhere durable (see
[Backups](/configuration/backups)), and, if you want it, setting up
external monitoring for the API process itself, since Crumb's own alerting
runs inside the API and can't page you if the API itself is down.

## Using it

Clone the repository on the target host, start your agent there, and ask
it to read `docs/AI-INSTALL.md` and follow it. The file is self-contained;
it does not assume the agent has read anything else in the repository
first, though it links out to deeper docs (motion recording, backups, TLS)
for background on specific decisions along the way.
