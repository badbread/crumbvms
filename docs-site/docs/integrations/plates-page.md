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
outlined. Click a row to play the clip of that read; the actions menu at the
end of the row copies the plate, names it, adds it to the watchlist, or makes
a PDF report.

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

## Keyboard

| Key | Action |
|---|---|
| `j` or Down | next row |
| `k` or Up | previous row |
| Enter | open the selected row |
| Right / Left | unfold / fold a grouped plate |
| Esc | clear the selection |
| `1`, `2`, `3` | Compact, Standard, Large |

The keys do nothing while you are typing in the search box.

## Good to know

- "Today", the hour-of-day chart and the 30-day chart use the server's time
  zone (the `TZ` setting of the Crumb server).
- Counts only include reads you are allowed to see. Two people with access to
  different cameras can see different numbers for the same plate.
- Plate history only goes back as far as your plate retention setting.
