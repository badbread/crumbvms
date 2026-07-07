---
title: Architecture
sidebar_label: Overview
slug: /architecture/
---

# Architecture

This section publishes a curated subset of Crumb's internal engineering
documentation for anyone who wants to understand the reasoning behind how
the recorder works, not just how to operate it. It's aimed at
contributors and the curious, not at day-to-day operators, the rest of
this site covers running Crumb; this section covers why some of its
harder design decisions were made the way they were.

## What's here

- **[Decision log](/architecture/decisions)**, significant architecture
  decisions, what was chosen, what was rejected, and the concrete triggers
  that would reopen each question.
- **[Recorder correctness](/architecture/recorder-correctness)**, a
  checklist of real defects found in an earlier implementation, and the
  invariants the current recorder satisfies by construction so they can't
  recur.
- **[Motion recording mechanism](/architecture/motion-recording)**, the
  RAM-buffer, persist-on-motion design behind Motion recording mode.

## How this section is generated

These pages are copied automatically from the project's `docs/` directory
at build time, from a fixed, reviewed whitelist, so that only documents
meant for a public audience end up here; internal audits, in-progress
plans, and anything not on the list are never published by accident. Each
page below carries a banner noting it's a generated copy and linking back
to its source in the repository, that source, not this page, is the one
to edit.
