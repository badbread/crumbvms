---
title: Responsible and lawful use
sidebar_label: Responsible use
slug: /responsible-use
---

# Responsible and lawful use of Crumb VMS

Crumb is a tool for recording your own cameras on your own hardware. It
sends nothing to anyone, your footage stays on the disk you chose. But
recording video, and especially audio, of people is regulated, and the law
makes you, the operator, responsible for how you use it, not the software
or its author.

:::caution
This is general information, not legal advice, and it is not exhaustive.
Laws vary widely by country, state, and even city, and they change. If
you're recording anything beyond your own clearly private space, check
your local rules, or ask a lawyer. Crumb can't and doesn't know your
obligations.
:::

## Video: the basics

Recording video for the security of your own property is generally
allowed, with real exceptions:

- **Don't record where people reasonably expect privacy**, bathrooms,
  changing areas, bedrooms, the inside of a neighbor's home, a tenant's
  private unit.
- **Pointing at others' property or public space raises the bar.** A
  camera that captures a public sidewalk, a shared hallway, or a
  neighbor's yard is treated more strictly than one that only sees your
  own enclosed property.
- **Landlords and employers** face additional rules, notice, proportionality,
  sometimes consultation, when monitoring tenants or employees.

## Audio: stricter than video

Crumb can record audio per camera. Audio is regulated more heavily than
video. Many US states are all-party-consent, meaning everyone recorded
must consent, and recording a conversation without that consent can be
both a crime and a civil wrong. If you're unsure, leave audio off, or
confine it to spaces where no one has a reasonable expectation of a
private conversation. The admin console warns you at the point you enable
audio, for exactly this reason.

## Face or plate recognition, via your own detector

Crumb runs no recognition itself. If you connect your own object detector
and configure it to identify named people or license plates, Crumb will
store and display those labels, and named biometric data is regulated in
some places (Illinois' BIPA, for example, imposes consent, notice, and
retention rules with real penalties). If you enable named recognition
through an integration, that's on you to do lawfully. See
[Integrations](/integrations/) for how the integration itself works.

## If you're in the EU or UK

Recording identifiable people almost certainly makes you a data
controller under GDPR or UK GDPR, with real obligations. A few highlights:

- **The "it's just my home camera" exemption is narrow.** The
  household/personal-use exemption evaporates the moment your camera
  captures a public path, the street, or a neighbor's property, even
  incidentally. Most doorbell and driveway cameras trip this without the
  owner realizing it.
- **Retention:** keep footage only as long as necessary for your stated
  purpose. There is no fixed legal number, the "30 days" or "72 hours"
  figures you'll hear are customary, not law. Pick a period tied to your
  actual purpose and be able to justify it. Crumb gives you two
  enforcement knobs per recording policy: the per-tier retention windows
  (how long live and archive footage are each kept) and an optional
  maximum retention cap that deletes everything older than N days across
  both tiers at once. The cap is off by default. One caveat: footage you
  explicitly protect (a protected bookmark) is never auto-deleted, so it
  can outlive the cap, unpin it once it's no longer needed. Crumb enforces
  whatever period you choose but can't tell you what the right period is,
  that's your call against your purpose and local law.
- **Signage:** you generally must tell people they're being recorded,
  visible signs identifying you, the purpose, and a contact, before they
  enter the recorded area.
- **A Data Protection Impact Assessment** is often required for monitoring
  public space, using face or plate recognition, or monitoring employees.
- **Subject access requests:** people can ask for a copy of footage of
  themselves, and you must be able to find, extract, and (redacting
  others) provide it within statutory windows. Crumb's clip and export
  tools by time range help with the extraction; redacting bystanders is
  still your manual job.

Your national data-protection authority, the ICO in the UK, CNIL or AEPD
or the German state authorities in the EU, publishes CCTV guidance, that's
the right place to start for specifics.

## The short version

Point cameras at your own property, be careful with audio and with
anything aimed at public space or a neighbor's property, tell people when
you're recording, keep footage only as long as you need it, and check
your local law before doing anything unusual. Crumb gives you the
controls; the responsibility is yours.

## Alpha tester terms

If you're running Crumb during its alpha period, a short set of tester
terms also applies: it's pre-release, unfinished software provided as is,
with no warranty, and you should not rely on it as your only security
system. The full terms live with the project's source
(`docs/ALPHA-TESTER-TERMS.md` in the repository) and cover feedback,
liability, and the scope of tester access.
