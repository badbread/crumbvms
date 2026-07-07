# TLS (HTTPS), Caddy sidecar

Crumb's API historically served plain HTTP only (`http://<host>:8080`), fine
on a trusted LAN, but passwords, JWTs, and video ride the wire cleartext.
This adds in-product TLS via a **Caddy sidecar** in `docker-compose.yml`,
turned on by default, with **zero breaking changes** for existing installs.

## What it does

- A new `caddy` service (`caddy/Caddyfile`) reverse-proxies the API
  (`api:8080` over the internal compose network) and terminates HTTPS on a
  published port, default **8443** (`CRUMB_HTTPS_PORT` in `.env` if you want
  a different one, kept off 443 so it never collides with something else
  already bound to that port on the host).
- The API's plain HTTP on **:8080 keeps working exactly as before.** Caddy
  doesn't replace it, it's an additional, encrypted way in. Nothing about
  the API changed; Caddy is a pass-through in front of it.
- On a fresh install with no domain, Caddy uses its **automatic internal CA**
  (`tls internal` in the Caddyfile / the `local_certs` global option): it
  mints its own root certificate once (stored in the `crumb_caddy_data`
  volume) and issues a leaf cert off of it for whatever hostname/IP you hit
  it on. No domain, no port-forwarding, no outbound calls to Let's Encrypt.

Reach it at:

```
https://<this-host>:8443
```

e.g. `https://192.168.1.50:8443`, same admin console / API as
`http://192.168.1.50:8080`, just encrypted.

## The self-signed-cert browser warning

Because the internal CA isn't in your OS/browser's trust store, the first
time you visit `https://<host>:8443` your browser will show a warning
("Your connection is not private" / "Warning: Potential Security Risk" /
similar), this is expected on a LAN install with no public domain name, not
a sign anything is broken. Your traffic is still fully encrypted; the
warning only means the browser can't verify the cert came from a CA it
already trusts.

Two ways to deal with it:

1. **Click through once per browser**, "Advanced" → "Proceed to
   `<host>` (unsafe)" (wording varies by browser). Most browsers remember
   this per-site after the first time.
2. **Trust Caddy's local CA properly** (removes the warning everywhere on
   that machine):
   - Get the root cert out of the running container:
     ```
     docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./crumb-local-ca.crt
     ```
   - Import `crumb-local-ca.crt` into your OS/browser trust store:
     - **Windows**: double-click the `.crt` → "Install Certificate" →
       "Local Machine" → "Place all certificates in the following store" →
       "Trusted Root Certification Authorities".
     - **macOS**: open in Keychain Access, add to "System", then set
       "Always Trust" in the cert's trust settings.
     - **Linux**: copy to `/usr/local/share/ca-certificates/`, run
       `sudo update-ca-certificates` (Debian/Ubuntu) or the equivalent for
       your distro; browsers using the system store will pick it up (Firefox
       has its own store, import via Settings → Privacy & Security →
       Certificates → View Certificates → Authorities → Import).
     - **Android/iOS**: install the `.crt` as a trusted CA profile (Settings →
       Security → "Install from storage" on Android; Settings → General →
       VPN & Device Management on iOS, then also enable full trust under
       Certificate Trust Settings).
   - This only needs to happen once per device/browser you use to reach
     Crumb, after that, `https://<host>:8443` is fully trusted with no
     warning.

Native clients (desktop/Android/iOS apps) currently talk to the API over
plain HTTP/RTSP by design (see "Non-breaking by design" below), the browser
warning above only applies if you point a **browser** at the HTTPS port.

## Non-breaking by design

- `docker-compose.yml`'s `api` service still publishes `0.0.0.0:8080:8080`
  unchanged. Any existing bookmark, desktop client "Server address", Android
  app config, or script hardcoded to `http://<host>:8080` keeps working with
  no changes required.
- The `caddy` service is purely additive: it depends on `api`, adds one new
  published port (`CRUMB_HTTPS_PORT`, default 8443), and two new named
  volumes (`crumb_caddy_data`, `crumb_caddy_config`) for its cert storage and
  autosaved config. If you don't want it, delete the `caddy:` block (and the
  two volumes) from `docker-compose.yml`, the rest of the stack is
  unaffected.

## Going HTTPS-only

Once you've confirmed HTTPS works for you (browser warning accepted or CA
trusted, per above), you can stop publishing the API's plain port so
*only* the encrypted path is reachable from the LAN:

1. In `docker-compose.yml`, under the `api:` service's `ports:`, remove (or
   comment out) the `"0.0.0.0:8080:8080"` line, or change it to
   `"127.0.0.1:8080:8080"` if you still want local/host-only plain-HTTP
   access for debugging.
2. `docker compose up -d` to apply.
3. Update any client "server address" settings to the `https://` URL.

Caddy needs no changes for this step, it already reaches `api` over the
internal compose network regardless of what's published to the host.

## Switching to a real domain + automatic Let's Encrypt

If you have a domain pointed at this host and can forward port 443 (and 80,
for the ACME HTTP-01 challenge) from your router/firewall to it, Caddy can
get you a real, browser-trusted certificate with zero manual renewal:

1. Edit `caddy/Caddyfile`:
   - Remove the `{ local_certs }` global options block and the
     `tls internal` line.
   - Replace the `:{$CRUMB_HTTPS_PORT} { ... }` site block with your domain:
     ```
     crumb.example.com {
         reverse_proxy api:8080
     }
     ```
2. Edit `docker-compose.yml`'s `caddy` service `ports:` to publish `80:80`
   and `443:443` instead of `CRUMB_HTTPS_PORT:8443` (Caddy needs 80 for the
   ACME challenge and to redirect to 443).
3. Make sure `crumb.example.com` resolves (public DNS) to this host's public
   IP, and that your router/firewall forwards 80 and 443 to it.
4. `docker compose up -d`. Caddy automatically requests, installs, and
   renews the certificate, no browser warning, no manual steps after that.

This is a bigger step (public DNS + port-forwarding) than the LAN-only
default, so it's left as a manual, documented opt-in rather than something
the base compose file does for you.

## Risks / residual gaps

- **Self-signed cert UX** is real friction for a first-time LAN user, the
  browser warning above is unavoidable without a domain. This is the
  standard trade-off for any self-hosted app with no public DNS name (Caddy,
  Portainer, Proxmox, etc. all show the same kind of warning by default).
- **Native clients (desktop/Android/iOS) still default to plain HTTP/RTSP**
  for their server-address/streaming config, this task only adds the HTTPS
  *option* at the infrastructure layer (Caddy in front of the API). Wiring
  each client to prefer/require HTTPS, and to trust (or pin) Caddy's
  internal CA so they don't need a manual per-device import, is future work
  (tracked alongside related hardening like revocable sessions / scoped media
  tokens, which matter more once the transport is encrypted).
- **RTSP (`:18554`) and the WebRTC media plane (`:8556`) are unaffected by
  this change**, they're go2rtc's own listeners, not proxied through Caddy,
  and continue to run unencrypted (with go2rtc's own Basic-auth/RTSP-auth on
  top, per the compose file's recorder-service comments, go2rtc is embedded
  in the recorder container). Encrypting those is a
  separate, larger effort (SRTP/DTLS or an RTSPS listener) not in scope here.
