---
title: TLS
sidebar_label: TLS
slug: /configuration/tls
---

# TLS

Crumb's API historically served plain HTTP only. That's fine on a trusted
LAN, but passwords, session tokens, and video otherwise ride the wire in
the clear. A Caddy sidecar adds in-product HTTPS by default, with no
breaking change for existing installs.

## What's running

A `caddy` service reverse-proxies the API and terminates HTTPS on a
published port, `8443` by default (`CRUMB_HTTPS_PORT` in `.env` if you want
a different one). The API's plain HTTP on `:8080` keeps working exactly as
before, Caddy is an additional, encrypted way in, not a replacement.

On a fresh install with no domain configured, Caddy uses its own automatic
internal certificate authority: it mints a root certificate once and
issues a leaf certificate for whatever host or IP you reach it on. No
domain, no port-forwarding, no outbound calls to a public certificate
authority.

Reach it at `https://<this-host>:8443`, the same admin console and API as
the plain HTTP port, just encrypted.

## The certificate warning

Because the internal certificate authority isn't in your browser's trust
store, the first visit to `https://<host>:8443` shows a warning. This is
expected on a LAN install with no public domain name, not a sign anything
is broken; the traffic is still fully encrypted, the browser just can't
verify the certificate came from an authority it already trusts.

Two ways to deal with it:

1. **Click through once per browser.** Most browsers remember this
   per-site after the first time.
2. **Trust Caddy's local certificate authority**, which removes the
   warning everywhere on that machine:

   ```bash
   docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./crumb-local-ca.crt
   ```

   Then import `crumb-local-ca.crt` into your OS or browser's trust store
   (Windows: double-click, install to Local Machine, Trusted Root
   Certification Authorities; macOS: Keychain Access, add to System, set
   Always Trust; Linux: copy to
   `/usr/local/share/ca-certificates/` and run
   `sudo update-ca-certificates`, or your distribution's equivalent).

Native clients (desktop, Android, iOS) currently talk to the API over
plain HTTP and RTSP by design; the certificate warning above only applies
if you point a browser at the HTTPS port.

## Going HTTPS-only

Once HTTPS works for you, either the warning is accepted or the
certificate authority is trusted, you can stop publishing the plain port
so only the encrypted path is reachable on the LAN:

1. In `docker-compose.yml`, under the `api` service's `ports`, remove or
   comment out `"0.0.0.0:8080:8080"`, or change it to
   `"127.0.0.1:8080:8080"` for host-local debugging only.
2. `docker compose up -d`.
3. Update any client's server address setting to the `https://` URL.

## A real domain and automatic Let's Encrypt

If you have a domain pointed at this host and can forward ports 80 and 443
from your router, Caddy can get you a real, browser-trusted certificate
with no manual renewal:

1. Edit `caddy/Caddyfile`: remove the internal-CA options block and the
   `tls internal` line, and replace the site block with your domain,
   proxying to `api:8080`.
2. Edit the `caddy` service's published ports to `80:80` and `443:443`
   instead of the default `8443`.
3. Point your domain's DNS at this host's public IP and forward 80/443 to
   it.
4. `docker compose up -d`. Caddy requests, installs, and renews the
   certificate automatically from then on.

This is a bigger step than the LAN-only default, public DNS and
port-forwarding, so it's left as a documented, manual opt-in rather than
something the base install does for you.

## What TLS here doesn't cover yet

Native clients still default to plain HTTP and RTSP for their own
server-address and streaming configuration; this adds the HTTPS option at
the infrastructure layer in front of the API. RTSP (`:18554`) and the
WebRTC media plane (`:8556`) are unaffected by this Caddy layer, they're
go2rtc's own listeners with their own Basic-auth on top, not proxied
through Caddy.

## Removing TLS entirely

If you don't want the Caddy sidecar at all, delete the `caddy:` block (and
its two named volumes) from `docker-compose.yml`. Nothing else in the
stack depends on it, and the rest is unaffected.
