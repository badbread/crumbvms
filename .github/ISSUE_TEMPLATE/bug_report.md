---
name: Bug report
about: Report something that isn't working as expected
title: ""
labels: bug
assignees: ""
---

<!--
Do NOT report security vulnerabilities here, see SECURITY.md for the private
disclosure path.
-->

## What happened

<!-- A clear, concise description of the bug and what you expected instead. -->

## Steps to reproduce

1.
2.
3.

## Component

<!-- Which part of Crumb is affected? Delete the ones that don't apply. -->

- [ ] Server, API (`services/api`)
- [ ] Server, recorder (`services/recorder`)
- [ ] Desktop client (Windows / macOS)
- [ ] Android app
- [ ] iOS app
- [ ] Web admin console (`/admin`)
- [ ] Not sure

## Logs

<!--
Relevant log output. For the server: `docker compose logs api` /
`docker compose logs recorder`. Scrub any secrets, tokens, or real IPs before
pasting.
-->

```
paste logs here
```

## Environment

- **Crumb version / commit:**
- **Deployment:** <!-- Docker Compose (pulled images / built from source), other -->
- **Host OS + arch:** <!-- e.g. Ubuntu 24.04 x86-64 -->
- **Client build (if a client bug):** <!-- desktop zip version, APK version, etc. -->
- **GPU:** <!-- none / NVIDIA + nvidia-container-toolkit -->

## Camera(s) involved (if relevant)

- **Make / model:**
- **Stream:** <!-- RTSP main/sub, resolution, codec if known -->
- **Via Frigate?** <!-- yes/no -->

## Anything else

<!-- Screenshots, config snippets (secrets removed), or extra context. -->
