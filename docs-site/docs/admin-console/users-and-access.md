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
- **View license plates**: see recognised plate reads and search the plate
  database, scoped to the role's cameras. This one is sensitive, a plate
  database is privacy-sensitive, so leave it off unless a role genuinely
  needs it.
- **Bookmarks**: how much [bookmark](/recording/bookmarks) access a person
  gets. Four levels: **None**; **Own** (create and see only their own);
  **View all** (see everyone's, but create and edit only their own); and
  **All** (view and manage everyone's).

Leave a permission off and that person simply doesn't see that capability. Someone
with live view but no Export, for instance, can watch cameras but can't pull
footage off the system.

## Which cameras they can see: access

Access is set in two layers. The **role** carries a base set of cameras that
everyone assigned to it can see. On top of that, an individual user can be
granted **extra cameras** beyond their role's set, for the one-off case where
a person needs a camera or two nobody else in their role should get.

Either way the boundary is the same: a viewer scoped to the two entrance
cameras sees only those two, everywhere in every client, live, timeline,
clips, and export all respect it. They have no way to know the other cameras
exist.

Administrators are the exception: an admin sees every camera and every setting.
Keep the number of admins small, and give everyone else a scoped role with just
the cameras they need.

## Adding a user

In the admin console's Users & Security section you add a user with a username and
password and pick their role. The role already carries its capabilities and its
base cameras; for a non-admin you can also grant extra cameras on top, just for
that user. They can sign in from any [client](/clients/) with those credentials
and will be held to exactly that boundary.

Because access is enforced by the server, not the app, a scoped user stays scoped
no matter which client they use or how they connect.
