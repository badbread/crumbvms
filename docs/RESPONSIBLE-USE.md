# Responsible & lawful use of CrumbVMS

CrumbVMS is a tool for recording **your own** cameras on **your own** hardware. It
sends nothing to us, your footage stays on the disk you chose. But recording
video (and especially audio) of people is regulated, and **the law makes *you*,
the operator, responsible** for how you use it, not the software or its author.

> **This is general information, not legal advice, and it is not exhaustive.**
> Laws vary widely by country, state, and even city, and they change. If you're
> recording anything beyond your own clearly-private space, check your local
> rules (or ask a lawyer). CrumbVMS can't and doesn't know your obligations.

## Video, the basics

Recording video for the security of your own property is generally allowed, with
big exceptions:

- **Don't record where people reasonably expect privacy**, bathrooms, changing
  areas, bedrooms, the inside of a neighbor's home, a tenant's private unit.
- **Pointing at others' property / public space raises the bar.** A camera that
  captures a public sidewalk, a shared hallway, or a neighbor's yard is treated
  more strictly than one that only sees your own enclosed property.
- **Landlords / employers:** monitoring tenants or employees triggers additional
  rules (notice, proportionality, sometimes consultation) in many places.

## Audio, stricter than video

CrumbVMS can record audio per camera. **Audio is regulated more heavily than video.**
Many US states are **all-party-consent** (everyone recorded must consent) —
recording a conversation without that consent can be a crime and a civil wrong.
If you're unsure, **leave audio off**, or confine it to spaces where no one has a
reasonable expectation of a private conversation. The admin console warns you at
the point you enable audio for this reason.

## Face / plate recognition (via your own Frigate)

CrumbVMS runs **no** recognition itself. If you connect **your own** Frigate and
configure it to identify named people or license plates, CrumbVMS will store and
display those labels, and named biometric data is regulated in some places
(e.g. Illinois' BIPA imposes consent, notice, and retention rules with real
penalties). If you enable named recognition, that's on you to do lawfully.

## If you're in the EU / UK (GDPR / UK GDPR)

Recording identifiable people almost certainly makes you a **data controller**
with real obligations. Highlights:

- **The "it's just my home camera" exemption is narrow.** The household/personal-
  use exemption evaporates the moment your camera captures a **public path, the
  street, or a neighbor's property**, even incidentally (the *Ryneš* case). Most
  doorbell/driveway cameras trip this without the owner realizing it.
- **Retention:** keep footage only **as long as necessary for your stated
  purpose**. There is **no fixed legal number**, the "30 days" / "72 hours"
  figures you'll hear are custom, not law. Pick a period tied to your actual
  purpose and be able to justify it. CrumbVMS gives you two enforcement knobs per
  recording profile: the per-tier retention windows (how long live/archive
  footage is kept) and an optional **Maximum retention** cap ("delete all footage
  older than N days", covering both live and archive at once). The Maximum
  retention cap is **off by default**, set it if you want a hard upper bound. One
  caveat: footage you explicitly **protect** (a protected bookmark) is never
  auto-deleted, so it can outlive the cap; unpin it when it's no longer needed.
  CrumbVMS enforces whatever period you choose but cannot tell you what the right
  period is, that's your call against your purpose and local law.
- **Signage:** you generally must **tell people they're being recorded** —
  visible signs identifying you, the purpose, and a contact, *before* they enter
  the recorded area.
- **DPIA:** a Data Protection Impact Assessment is often required for monitoring
  public space, using face/plate recognition, or monitoring employees.
- **Subject access requests:** people can ask for a copy of footage of
  themselves; you must be able to find, extract, and (redacting others) provide
  it within statutory windows. CrumbVMS's clip/export by time range helps, but
  redacting bystanders is your manual job.

Your national data-protection authority (the **ICO** in the UK; **CNIL**,
**AEPD**, the German state DPAs, etc. in the EU) publishes CCTV guidance, start
there.

## The short version

Point cameras at your own property, be very careful with audio and with anything
aimed at public space or neighbors, tell people when you're recording, keep
footage only as long as you need it, and check your local law before doing
anything unusual. CrumbVMS gives you the controls; the responsibility is yours.
