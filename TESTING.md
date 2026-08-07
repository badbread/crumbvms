# Testing CrumbVMS

Thank you for helping test Crumb. This page is the short version of everything a new
tester needs: what you are signing up for, how to get it running in about fifteen
minutes, what is worth poking at, and how to write a report that can actually be acted
on.

## Who this is for

You run cameras at home or in a small shop, you are comfortable with a terminal and
`docker compose`, and you are willing to run early software next to (not instead of)
whatever you already trust. Bonus points if you already run Frigate, use Home
Assistant, or have camera brands the maintainer does not own.

You do not need to be a developer. You do not need to read Rust. If you can stand up a
Docker Compose stack and describe what you saw, you can test Crumb.

## What you are signing up for

Set expectations honestly, because that is the whole point of an alpha:

- **This is alpha software built by one person.** Things will break. Some of them will
  be embarrassing. That is what you are here to find.
- **Do not make Crumb your only recorder yet.** Run it alongside your existing setup, or
  on cameras where a gap in the footage is survivable. Losing footage is the one bug
  that matters most, so it gets the most scrutiny, but "most scrutiny" is not "proven on
  your hardware."
- **Crumb is designed to be LAN-only.** The default install binds to your local network
  and nothing phones home. Please do not port-forward it to the public internet to test
  it. If you need remote access, put it behind Tailscale, WireGuard, or a VPN you
  already trust.
- **Nothing leaves your box.** No telemetry, no analytics, no accounts, no cloud. That
  also means the maintainer sees nothing unless you send it, which is why the reporting
  section below matters so much.
- **Read the [Alpha Tester Terms](docs/ALPHA-TESTER-TERMS.md) first.** Crumb is provided
  AS-IS with no warranty, it is not a replacement for a monitored alarm system, and
  lawful use of your cameras is on you. The console asks you to acknowledge this once on
  first run.
- **Expect to upgrade often.** Fixes land quickly. Pulling a newer image and restarting
  is normal, see the [changelog](CHANGELOG.md) for what changed.

## Fifteen-minute quickstart

The full instructions live in the [README install section](README.md#install). The
condensed version, on a Linux host with Docker installed:

```bash
git clone https://github.com/badbread/crumbvms.git
cd crumbvms
./scripts/setup-env.sh     # generates .env with strong secrets, prints your admin password
docker compose pull
docker compose up -d
docker compose ps          # every service should be running or healthy
```

Then open `http://<your-server-ip>:8080/admin`, sign in as `admin` with the password
`setup-env.sh` printed, and work through the first-run wizard: accept the tester terms,
confirm the server address, set storage and retention, scan for cameras, add a few.

Two other paths if you prefer them:

- **Hand it to a coding agent.** [`docs/AI-INSTALL.md`](docs/AI-INSTALL.md) is an
  agent-runnable runbook with a verification step after every step. Give it to Claude
  Code, Cursor, or similar and let it do the install. This is the least hands-on path.
- **Build from source** instead of pulling images:
  `docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build`

Native clients (Windows and macOS desktop, Android) are a separate download, see
[docs/CLIENTS.md](docs/CLIENTS.md). The web console at `/admin` works on its own if you
would rather not install anything else yet.

## What to test

Test in the order that matches how you would really use it. Anything that surprises you
is worth reporting, including wording that confused you.

**Install and first run**

- Did `setup-env.sh` and `docker compose up -d` work on your host and OS, first try?
- Did the wizard's storage step correctly see your disk and its free space?
- Did the camera scan find your cameras? Which ones did it miss, and what are they?
- Anything in the wizard you had to guess at, back out of, or look up?

**Live view (the wall)**

- Do all your cameras show video, and how long does the first frame take?
- Multi-camera walls: 4, 9, 16 tiles. Does it stay smooth? What does CPU do?
- Save a view, rearrange it, reopen it. Did it come back the way you left it?
- Audio, PTZ, and presets if your cameras have them.

**Playback and the timeline**

- Scrub the timeline hard, backwards and forwards, across segment boundaries. This is
  the feature Crumb exists for, so break it if you can.
- Jump to a specific date and time. Step frame by frame.
- Export a clip, and try the batch export list with several clips at once.

**Recording and motion**

- Leave it recording overnight, then check the next morning for gaps in the timeline.
- Motion detection: are you getting real events, missed events, or a wall of false
  triggers from trees and traffic? Which detector and threshold were you on?
- If you try Motion recording mode, please read
  [docs/MOTION-RECORDING.md](docs/MOTION-RECORDING.md) first and consider running it in
  shadow mode before trusting it with footage you care about.
- Retention: does storage settle where you told it to, or does the disk keep filling?

**Integrations, if you have them**

- **Frigate:** do detections show up on the Crumb timeline, and do the labels match?
- **Home Assistant:** connect it in the console, link a camera to an entity, and put
  badges on the live video. Do the badges stay in sync with what HA shows?

**Clients**

Please try every client you can, and say which one a bug is in:

- Web console at `/admin` (Chrome, Firefox, Safari, Edge)
- Desktop client (Windows, macOS)
- Android app
- iOS is built but not yet distributable, see the README for why

**Cameras**

Crumb has an in-app camera identifier, and adding a camera can file a prefilled
"contribute this camera" report for the
[compatibility database](https://docs.crumbvms.com/cameras/compatibility). Please let it
file yours, especially for brands and models nobody has reported yet. Every entry saves
the next person an evening.

## How to report well

A good report is one the maintainer can act on without a back-and-forth. That means
three things: what you did, what happened, and the diagnostics.

**1. Exact steps.** Numbered, from a known starting point, including the values you
typed. "Added a camera and it failed" is hard to act on. "Cameras, Add camera, pasted
`rtsp://<ip>:554/Streaming/Channels/102`, clicked Test stream, it spun for 30 seconds
then showed an error" is easy to act on. Include what you expected instead.

**2. The diagnostics.** Attach whichever of these apply. All three are scrubbed or
easy to scrub, but skim them before posting anyway.

- **Server diagnostics bundle.** In the admin console, go to **Settings, Detection &
  clips, Diagnostics** and click **Download bundle**. It is admin-only and produces a
  small JSON file with the server's version, effective config, key environment, and
  database schema state. Secrets (tokens, passwords, credentials embedded in URLs) are
  redacted before it is written, and it never contains footage or live logs. This is the
  single most useful thing you can attach to a server-side bug.
- **Desktop client diagnostics.** In the desktop client, open **Settings,
  Diagnostics**, then **Export logs…** (or **Copy to clipboard**). It captures the
  client's warnings and errors, plus an opt-in **Verbose logging** mode that records
  HTTP and player detail. Tokens are redacted as they are captured, so an export never
  contains one. If a bug is intermittent, turn on verbose logging, reproduce it, then
  export.
- **Container logs.** From the directory you installed into:

  ```bash
  docker compose logs --tail 500 api > api.log
  docker compose logs --tail 500 recorder > recorder.log
  docker compose ps
  ```

  Attach the files rather than pasting thousands of lines. Scrub anything you would not
  want public. LAN IPs and camera names are fine and are not treated as sensitive.

**3. Versions and environment.** Server version or image tag, which client and its
version, install method (pulled images or built from source), host OS and architecture,
and camera make and model when the bug involves a camera. The issue form asks for all of
this, so filling the form out is enough.

**Where to file:**

- **Bugs and rough edges:** [GitHub Issues](https://github.com/badbread/crumbvms/issues),
  using the **Bug report** form. Confusing wording, a step you had to guess at, or a
  layout that fought you all count as bugs. Please file them.
- **Camera compatibility:** the **Camera compatibility report** form, or the one-click
  contribution from the console.
- **Ideas and feature requests:** the **Feature request** form. For anything large,
  opening an issue to discuss it first is better than building it, see
  [CONTRIBUTING.md](CONTRIBUTING.md).
- **Security vulnerabilities:** never in a public issue. Use the private reporting path
  in [SECURITY.md](SECURITY.md). Crumb records security cameras, so a vulnerability is a
  privacy hazard and gets handled quietly and quickly.

One issue per problem. Two unrelated bugs in one thread means one of them gets lost.

## What happens next

Crumb is solo-maintained, so response time varies, but every report is read. Bug reports
and small fixes are the most valuable contribution there is, and the ones most likely to
land quickly. If you want to send a fix rather than a report, start with
[CONTRIBUTING.md](CONTRIBUTING.md).

Thank you for testing. Early testers are how this gets good.
