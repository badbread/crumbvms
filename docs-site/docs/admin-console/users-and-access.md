---
title: Users & access
sidebar_label: Users & access
slug: /admin-console/users-and-access
---

# Users & access

Not everyone who logs into Crumb should see everything. A house-sitter might need
the front and back cameras for a week; a family member might get live view but
not the ability to export footage; only you might touch settings. Crumb's Users &
Security section (in the [admin console](/admin-console/)) lets you draw those
lines.

There are two pieces: **what a person can do** (their role) and **which cameras
they can see** (their access).

## What a person can do: roles

A role is a named bundle of permissions you can hand to one person or many. You
create a role once (for example "Family" or "Guard"), decide what it's allowed to
do, then assign it to users. When you change the role later, everyone with it
updates at once.

The permissions a role can grant include:

- **Playback**: review recorded footage, not just the live view.
- **Clips**: open the [Clips](/playback/clips) feed of detections and motion.
- **Export**: build and download [export](/playback/export) archives.
- **PTZ**: pan, tilt, and zoom cameras that support it.
- **Manage views**: create and edit saved camera layouts.
- **Bookmarks**: whether a person sees only their own
  [bookmarks](/recording/bookmarks), everyone's, or none.

Leave a permission off and that person simply doesn't see that capability. Someone
with live view but no Export, for instance, can watch cameras but can't pull
footage off the system.

## Which cameras they can see: access

Separately from what they can do, each user can be limited to specific cameras. A
viewer scoped to the two entrance cameras sees only those two, everywhere in every
client: live, timeline, clips, and export all respect the same boundary. They have
no way to know the other cameras exist.

Administrators are the exception: an admin sees every camera and every setting.
Keep the number of admins small, and give everyone else a scoped role with just
the cameras they need.

## Adding a user

In the admin console's Users & Security section you add a user with a username and
password, pick their role, and (for non-admins) choose which cameras they can see.
They can sign in from any [client](/clients/) with those credentials and will be
held to exactly that boundary.

Because access is enforced by the server, not the app, a scoped user stays scoped
no matter which client they use or how they connect.
