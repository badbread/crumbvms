---
title: Platform notes
sidebar_label: Platform notes
slug: /getting-started/platform-notes
---

# Platform notes

Crumb is a Docker Compose stack, so in principle it runs anywhere Docker runs.
In practice one thing decides whether an install works or quietly does nothing:
**can the recorder write to your storage?**

The recorder runs as user ID **1001** inside its container. It writes every
frame of footage to the directory you point `MEDIA_HOST_PATH` at. If uid 1001
cannot write there, the failure is nasty because it does not look like a
failure:

- live view still works, because live video never touches the disk
- the setup wizard still shows green, because the API mounts storage read only
  and cannot test writing
- and nothing, ever, is recorded

`scripts/setup-env.sh` now tests this for you before you start the stack. It
detects the filesystem type, tries to write to the media directory as uid 1001,
and refuses to finish if the answer is definitely no. The rest of this page is
what that test cannot tell you: which platforms people actually install on, and
where each one trips.

## Status at a glance

| Platform | Status | Why |
|---|---|---|
| Debian or Ubuntu, bare metal or VM | **Tested** | What CI builds and what the developer runs daily. |
| Proxmox, Debian or Ubuntu VM guest | **Tested** | A VM guest is just a Linux host. No Proxmox specific requirements. |
| Proxmox, unprivileged LXC | Should work, not verified | Docker in LXC is routine but needs nesting turned on, and the container's user ID shift changes what `chown 1001` means. |
| Synology or QNAP, Container Manager | Untested | Storage is usually a shared folder with its own user mapping. `chown` often does not stick. |
| Unraid | Untested | User shares (`/mnt/user`) are a FUSE layer that synthesises ownership from settings, not from the disk. |
| Windows or macOS, Docker Desktop / WSL2 | Untested | Bind mounts cross a filesystem translation layer and do not carry Linux ownership. Apple Silicon also emulates. |
| Raspberry Pi or any ARM board | **Not supported yet** | Published images are amd64 only. |

"Tested" means the project is actually run this way. "Untested" means nobody has
reported success or failure, not that it is known to be broken. If you get one
of the untested rows working, or find where it breaks, please open an issue: it
is how these rows change.

## The one check that matters

Whatever platform you are on, this is the test. Run it against your media
directory before you add cameras:

```bash
sudo -u '#1001' touch /path/to/your/media/.crumb-write-test
sudo rm /path/to/your/media/.crumb-write-test
```

If the `touch` succeeds, recording will work. If it fails, fix that first.
Nothing else on this page matters until it passes.

## Debian or Ubuntu, bare metal or VM

The reference platform. Follow
[Install with Docker Compose](/getting-started/install-docker-compose) and
`setup-env.sh` handles the media directory ownership for you if you run it with
`sudo`, or tells you the exact command to run if you do not.

**What to check:** that `MEDIA_HOST_PATH` is on a real data disk and not the
root filesystem. Footage fills disks. A full root disk takes the whole machine
down, not just recording.

## Proxmox

Both guest types work. Pick based on how you want to handle the GPU, and put
footage on a dedicated dataset or disk either way.

**VM guest.** Nothing special. It is an ordinary Linux host. If you want
hardware motion decode, pass the GPU through with PCIe passthrough, which
dedicates the card to that one guest.

**Unprivileged LXC.** More efficient, and the GPU stays shareable because you
bind the render node in rather than passing the whole card. Two things to set
up:

- Docker needs nesting: `pct set <id> --features nesting=1`, or tick "Nesting"
  in the GUI. Some setups also need `keyctl=1`.
- **User IDs are shifted.** An unprivileged container maps its uid 0 to a high
  uid on the Proxmox host, commonly 100000. So container uid 1001 is host uid
  101001. If you attach storage as a mount point from the host, set ownership
  using the host side number:

  ```bash
  # on the Proxmox HOST, for the default 100000 offset
  chown -R 101001:101001 /tank/crumb-media
  ```

  Getting this wrong is the single most likely reason a Proxmox LXC install
  records nothing.

**What to check:** run the write test above from inside the container. If
Docker in LXC fights you, particularly with NVIDIA, fall back to a VM. That
tradeoff is covered in
[Install with an AI agent](/getting-started/install-with-ai-agent).

## Synology and QNAP

Container Manager (Synology) and Container Station (QNAP) both run standard
Docker, so the stack itself is not the problem. Storage is.

**Known sharp edges:**

- Media usually lives in a shared folder. The NAS decides ownership through its
  own user and permission model, and a `chown 1001:1001` from inside a terminal
  session may be reverted, ignored, or blocked outright.
- If you mount the share over SMB rather than using a local volume, ownership
  comes from the mount options, not from the disk. Every file appears owned by
  whatever uid the mount was told to use.
- Some models place shares on a filesystem where the container user cannot be
  granted access at all without creating a matching NAS user.

**What to check:**

1. Prefer a **local volume path** on the NAS over an SMB or network mount. A
   local path behaves like normal Linux storage.
2. Create a user with uid 1001 on the NAS, or give your media folder permissions
   that allow uid 1001 to write.
3. Run the write test. Do not skip it. This is the platform where "it looked
   fine" most often means "it recorded nothing".

## Unraid

Unraid installs are common and the stack should run, but the default storage
path is the thing to think about.

**Known sharp edges:**

- `/mnt/user/...` is a **FUSE user share**. Ownership is presented by the share
  layer based on your share settings, not stored on the underlying disk, so
  `chown` may appear to succeed and change nothing that the container sees.
- The user share layer also adds overhead on write heavy workloads, and
  continuous recording is exactly that.
- Docker on Unraid commonly remaps to the `nobody:users` pair (uid 99, gid 100),
  which is not uid 1001.

**What to check:**

1. Consider pointing `MEDIA_HOST_PATH` at a **specific disk or a cache pool**
   (`/mnt/disk1/...` or `/mnt/cache/...`) rather than `/mnt/user/...`. You give
   up share spanning and get predictable ownership and faster writes.
2. Set the share's Access Mode and ownership so uid 1001 can write, or adjust
   the container's user mapping to match what your share grants.
3. Run the write test.

## Windows and macOS, Docker Desktop or WSL2

Fine for trying Crumb out. Not what you want for a recorder that runs for
months.

**Known sharp edges:**

- A bind mount from a Windows drive or a macOS folder crosses a translation
  layer (9p or virtiofs). Linux file ownership is synthesised, so `chown 1001`
  is meaningless and permissions come from the mount configuration.
- Writing continuous video across that layer is much slower than writing to a
  native Linux filesystem.
- Docker Desktop's virtual machine has its own disk size limit, which footage
  will reach.
- **Apple Silicon Macs run the server images under emulation**, because they are
  amd64 only. Expect it to be slow.

**What to check:**

1. On WSL2, keep `MEDIA_HOST_PATH` inside the **WSL filesystem**
   (`/home/you/crumb-data`), not on `/mnt/c/...`. This avoids the translation
   layer entirely and is much faster.
2. On macOS, use a Docker named volume or a path inside the VM rather than a
   bind mount from your home folder.
3. Run the write test.

## Raspberry Pi and other ARM boards

**The Crumb server does not run on ARM today.** The published `api` and
`recorder` images are built for `linux/amd64` only. This is a deliberate choice,
not an oversight: the ARM build was an emulated compile that added roughly an
hour to every deploy, for no known ARM operator.

Your options right now:

- Run the server on any amd64 machine. A small mini PC is inexpensive and will
  outperform a Pi at continuous recording anyway.
- Build the images yourself on the ARM host. Nothing in the code is amd64
  specific, so this is expected to work, but it is not tested and you are on
  your own for it.

**The clients are unaffected.** The Android app ships its own build, and the
desktop app is built separately. Only the server side is amd64 only.

This is demand gated. If you want to self host the Crumb server on ARM, open an
issue and say so. A real operator asking is exactly the trigger for adding ARM
images back.

## Still not recording?

Work through
[Troubleshooting](/troubleshooting/), and check the recorder's own alert: it
raises a loud `storage_unwritable` warning in the admin console when it cannot
write, which is the definitive answer for a stack that is already running.
