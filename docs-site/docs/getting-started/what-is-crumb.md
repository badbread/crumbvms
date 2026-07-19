---
title: What is Crumb VMS
sidebar_label: What is Crumb VMS
slug: /getting-started/what-is-crumb
---

# What is Crumb VMS

Crumb VMS is a serious video management system for your own security cameras:
the recorder, live wall, and scrubbable timeline you would expect from a
commercial, installer-grade platform, built to run on your own hardware.

The recorder, storage, and every client are software you run yourself: a Rust
backend, a Postgres database, native desktop and Android apps, and a web admin
console.

## Why it exists

Cameras at home have been running for years without software that fit. The
serious commercial platforms, the kind that run control rooms, are built for
professional installers: they are capable but expensive, often cloud-locked
or Windows-only, and not aimed at someone who just wants to run their own
cameras well. The self-hosted alternatives lean the other way: excellent at
object detection, but the day-to-day experience of actually reviewing
footage, scrubbing a timeline, and watching a wall of cameras is often an
afterthought.

Crumb is the piece that was missing between those two worlds: a recorder
with a timeline you can actually scrub across a dozen cameras, including 4K
H.265 with no server-side transcode, a multi-camera live wall, fast batch
export, and per-camera user roles. It does not try to redo object detection.
If you already run (or want to run) an object detector, Crumb is built to
sit next to it, not replace it.

That it also happens to be private, no cloud, no telemetry, no account,
plain files on a disk you own, matters and is part of the design, but it is
the "how," not the "why." The starting problem was simply that the operator
experience did not exist yet at this price point.

## What Crumb actually does

- **Records** your cameras (RTSP, ONVIF-discoverable) to plain MP4 files on
  disk, indexed by a Postgres database that is the single source of truth
  for what exists and where.
- **Plays back** a frame-level, scrubbable timeline per camera, with jump to
  next/previous motion event and digital zoom into a clip, decoded natively
  on the client (no server transcode).
- **Shows a live wall** of multiple cameras at once, with saveable per-device
  layouts, carousels, PTZ tiles, and on-video ONVIF pan/tilt/zoom control.
- **Retains footage** according to named policies (continuous or
  motion-triggered, size caps, time caps, storage tiers). Every camera
  belongs to exactly one named policy; pointing several cameras at the same
  policy is how they share retention settings.
- **Exports** a selected span, or a batch list built up across a review
  session, to MP4 or an encrypted archive.
- **Controls access** with custom roles and per-camera grants, so a limited
  account can be restricted to specific cameras or to live-only.

## What Crumb deliberately does not do

- **It does not run its own object or face detection.** That is left to a
  dedicated detector you already run (or could run) independently. If you
  point Crumb at your own instance of one, Crumb will show its detections as
  icons on the timeline. See [Integrations](/integrations/) for how that works.
- **License-plate reading is the one exception.** Crumb ships an opt-in,
  fully local plate reader (fast-alpr) that runs on your own hardware, no
  cloud and no third-party account, and you can also feed plate reads in from
  your own Frigate instead. Both are off by default and stay on your box. See
  [Integrations](/integrations/) for how to turn it on.
- **It does not require an account, a subscription, or any connection to a
  vendor's servers.** Setup happens entirely on your own network.
- **It does not send footage, thumbnails, metadata, or usage statistics
  anywhere.** There is nothing to opt out of, because there is nothing being
  sent.

## Who this is for

Crumb is aimed at people comfortable running a Docker Compose stack on a
Linux host and editing a configuration file when needed: a home lab, a small
property, a workshop. It is under active development by one maintainer. The
recorder, the Windows desktop client, and the Android app are the
most-used, most-tested paths today; the web console works end to end; the
macOS and iOS apps run but are rougher around the edges. See
[Requirements](/getting-started/requirements) for what a host needs, and
[Install with Docker Compose](/getting-started/install-docker-compose) to
get a server running.

Before you rely on Crumb for anything, read
[Responsible & lawful use](/responsible-use): recording people, and
especially audio, is regulated, and the responsibility for lawful use is
always the operator's, not the software's.
