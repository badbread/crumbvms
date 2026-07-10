# Camera compatibility database

`camera-compatibility.json` is the source of truth for Crumb's list of
community-tested cameras: what works, the quirks people have hit, and the fixes.
It is rendered into the published page at
[`docs-site/docs/cameras/compatibility.md`](../docs-site/docs/cameras/compatibility.md)
by [`scripts/gen-camera-compat.mjs`](../scripts/gen-camera-compat.mjs).

**This data is human-curated and contributed by pull request only.** Crumb never
auto-collects it: no telemetry, no phone-home, nothing about your cameras leaves
your control. If you want to help the next person, add your camera and open a PR.

## Adding or updating a camera

1. Edit `camera-compatibility.json` (add an entry to the `cameras` array, or
   improve an existing one).
2. Regenerate the docs page:
   ```bash
   node scripts/gen-camera-compat.mjs
   ```
3. Commit both the JSON and the regenerated
   `docs-site/docs/cameras/compatibility.md`.
4. Open a PR. Keep it factual and first-hand; note how you tested.

The generator is zero-dependency (Node built-ins only), so step 2 needs nothing
installed beyond Node.

## Entry schema

```jsonc
{
  "make": "Uniview",              // required: manufacturer
  "model": "IPC2A24SE-ADF40KMC",  // required (use "" if unconfirmed): exact model
  "aka": ["other names"],         // optional: alternate names/rebrands
  "category": "LPR / ANPR",       // optional: camera type
  "streams": {
    "main": { "codec": "H265", "notes": "..." },  // notes optional
    "sub":  { "codec": "H264", "notes": "..." }
  },
  "support": {                    // each value: yes | partial | no | unknown
    "recording":    "yes",
    "desktop_live": "yes",
    "web_live":     "yes",
    "android_live": "partial",
    "ios_live":     "unknown",
    "playback":     "yes",
    "onvif":        "yes",
    "ptz":          "unknown"
  },
  "quirks": [                     // optional; omit or [] if none
    {
      "summary": "one-line headline",
      "affects": ["android"],     // which surfaces: android, ios, desktop, web, server
      "detail":  "what happens and why",
      "fix":     "the workaround"
    }
  ],
  "recommended_settings": ["..."],   // optional
  "tested": { "by": "handle", "date": "YYYY-MM-DD", "method": "how you verified" },
  "references": ["https://..."]      // optional supporting links
}
```

### Conventions

- `support` values are exactly `yes`, `partial`, `no`, or `unknown`. `partial`
  means "works with a caveat", and that caveat belongs in `quirks`.
- Keep prose free of `<` and `{` characters: the page is rendered through MDX,
  which treats them as markup.
- Do not put LAN IPs, credentials, or stream URLs in entries. Make, model, and
  settings are all a reader needs.
