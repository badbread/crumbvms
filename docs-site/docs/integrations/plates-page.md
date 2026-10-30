---
title: The Plates page (desktop)
sidebar_label: Plates page (desktop)
slug: /integrations/lpr/plates-page
---

# The Plates page

The Plates tab in the Windows desktop app is where you review license-plate
reads. Besides the raw list of reads, it tells you who is a regular, who is
new, and who you have never seen before, so you can tell a neighbour from a
stranger at a glance. You need the **View license plates** permission, and you
only ever see reads (and counts) from cameras you have access to.

For turning plate recognition on, choosing an engine and managing the
watchlist, see [License-plate recognition](./license-plate-recognition.md).

## Today at a glance

The strip across the top summarizes today on your server's clock:

- **Reads today**: every plate read since midnight.
- **Unique plates**: how many different plates that was.
- **New plates**: plates seen for the first time ever today.
- **Watchlist hits**: reads of plates on your watchlist.
- **Regulars vs strangers**: today's plates split into **regulars** (seen at
  least 5 times in the last 30 days), **returning** plates (seen before, but
  not that often), and **first-time** plates.

Every tile and every part of the split bar is a filter. Click **New plates** to
list only first-time plates, click a colour in the split bar to see only
regulars, returning or first-time plates, and click the same tile again (or
the filter chip in the toolbar) to clear it. **Unique plates** switches on
grouping by plate (see below).

If your server is older than the desktop app, the strip is hidden and the
history columns show a dash. Everything else works as before.

## The list

Each row is one pass of a car (duplicate reads of the same car within a few
seconds, including reads from both engines, are folded together; the layers
button in the toolbar turns that off). A row shows:

- the camera frame and the plate cut out of it,
- the plate, its name if you gave it one, and marks such as **NEW**,
  **WATCHLIST**, **4x TODAY** (the fourth read of that plate today) and
  **UNUSUAL HOUR** (this plate almost never shows up at this hour),
- its history: how many times it has been seen, when it was last seen before
  today, and when it was first seen,
- a small chart of its last 30 days,
- the time of the read and how confident the engine was.

A coloured stripe on the left edge marks watchlist plates (pink), new plates
(green) and regulars (amber).

Hover over a plate crop to see a larger view of the frame with the plate
outlined. Click a row to open the plate's profile (below); the actions menu at
the end of the row copies the plate, names it, corrects a misread (see below),
adds it to the watchlist, or makes a PDF report.

### Density

**Compact**, **Standard** and **Large** change the whole row at once: Compact
is text only with one read per line, Standard shows a frame and plate crop,
and Large makes both big enough to read the plate without opening anything. On
a narrow window the frame column drops out before the plate crop does.

### Group by plate

Turn on **Group by plate** to fold every read of the same plate into one row.
The row says how many reads it stands for; click that (or press the right
arrow) to unfold the earlier reads under it.

### Loading more

The list loads 200 reads at a time. **Load more** at the bottom fetches the
next 200 for the same search and time range.

## Grid

The grid button in the toolbar shows the same reads as cards: the camera frame
large, with the plate cut out and pinned in a corner. The controls above the
cards change them right away:

- **Show**: the plate inset, or the frame only.
- **Inset size** (S, M, L) and **Inset corner** (TL, TR, BL, BR).
- **Loupe**: a round magnifier that follows the mouse over the frame, at 2x
  or 3x, handy for reading a plate or a car's details without opening it.
- **Tall cards**: adds a small chart of the hours of the day this plate
  usually shows up, with the hour of this read highlighted.

Each card shows how many times the plate has been seen and when it was last
seen before today, plus NEW, Watchlist, Regular and Unusual hour marks and the
plate's name. Hover a card for Copy, Name, Watchlist and Report buttons. With
**Group by plate** on, a plate with several reads becomes one stacked card
showing the number of reads. The header filters, `j` / `k` and Enter work
the same as in the list, and clicking a card opens the plate's profile.

## Plate profile

Clicking a row or a card opens everything known about that plate:

- the plate, the crop from the read you clicked, its name (admins can edit it
  with the pencil) and the watchlist star (admins can add or remove it),
- first and last seen, total reads, and reads in the last 30 and 7 days,
- a one-line summary in plain English, for example "Usually arrives between
  5 and 6 PM, mostly on Driveway LPR", which also points out when the read you
  opened came at an unusual hour for this plate,
- a 30-day activity chart, a 24-hour clock showing when the plate usually
  shows up (midnight at the top), and which cameras see it most,
- its recent visits. Reads on the same camera a few minutes apart count as one
  visit, so a car sitting at the gate is one line, not ten. Click a visit to
  play its clip (or jump to the timeline when there is no clip).

**Play clip**, **View on timeline**, **Copy plate** and **Report** act on the
read you opened the profile from. Press Esc or **Back to plates** to return to
the list; with the profile open, `j` and `k` step to the next and previous
plate in the list.

## Correcting a misread plate

Plate readers sometimes get one character wrong, so the same car shows up as
two plates, for example `GIF2GAB` and `GIT2GAB`. You can tell Crumb that one is
a misread of the other, and from then on they count as one car everywhere:
in the list, the history and the charts, today's totals, the profile, plate
names and watchlist alerts.

1. Open the misread plate's actions menu (the three dots at the end of the row)
   or its profile, and choose **Correct plate...**.
2. Type the real plate, or click one of the **likely matches**. Crumb suggests
   plates you have already seen that are one or two characters away, with how
   often each was seen. Look-alike characters such as `O` and `0` count as a
   match.
3. Check the sentence under the field, for example "GIT2GAB's 12 reads will
   count as GIF2GAB", and click **Correct**.

Future reads of the misread count as the real plate too. Crumb never changes
the reads themselves: the profile of the real plate lists its **known
misreads**, and **Undo** there (or in the message right after you correct)
turns a correction back off.

Only admins can correct plates, the same as naming them. Everyone else sees
the corrected plates. The A/B engine benchmark keeps scoring each engine on
what it actually read.

## Keyboard

| Key | Action |
|---|---|
| `j` or Down | next row |
| `k` or Up | previous row |
| Enter | open the selected plate's profile |
| Right / Left | unfold / fold a grouped plate |
| Esc | close the profile, or clear the selection |
| `1`, `2`, `3` | Compact, Standard, Large |

The keys do nothing while you are typing in the search box.

## Good to know

- "Today", the hour-of-day chart and the 30-day chart use the server's time
  zone (the `TZ` setting of the Crumb server).
- Counts only include reads you are allowed to see. Two people with access to
  different cameras can see different numbers for the same plate.
- Plate history only goes back as far as your plate retention setting.
