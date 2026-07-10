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

The file is `{ "schema_version": 1, "cameras": [ <entry>, ... ] }`. Each entry:

```jsonc
{
  "make": "Uniview",              // required: manufacturer (display form)
  "model": "IPC6322SR-X22P-D",    // required (use "" if unconfirmed): exact model
  "aka": ["other names"],         // optional: alternate names/rebrands
  "category": "PTZ / LPR",        // optional: camera type

  // OPTIONAL but important: the `match` block is what lets the in-app matcher
  // recognize this camera from its ONVIF make/model. An entry WITHOUT a valid
  // `match` block is documentation-only (it shows on the page but is never
  // auto-matched to anyone's camera). All match strings are normalized
  // (lowercased, non-alphanumerics stripped) before comparison.
  "match": {
    "make": "uniview",                  // normalized manufacturer, required in the block
    "make_aliases": ["unv"],            // other normalized names the camera may report
    "models": ["ipc6322sr-x22p-d"],     // normalized exact model strings
    "model_globs": []                   // optional, '*' wildcard only (NO regex)
  },
  "firmware_observed": ["HCMN-B2201.6.9.220415"], // optional, informational only;
                                                  // firmware NEVER gates matching

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
    "ptz":          "yes"
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
- `match` strings are normalized (lowercased, non-alphanumerics removed), so
  write them lowercase. Manufacturers report messy strings (Uniview reports
  `UNIVIEW` on some lines and `UNV` on others; Dahua OEMs report a storefront
  brand), so list every form you've seen in `make_aliases` / `models`.
  `model_globs` supports the `*` wildcard only; regex is not allowed.
- `firmware_observed` is informational (shown as "reported on firmware X"). It
  never affects matching, firmware version formats are vendor-arbitrary.
- Keep prose free of `<` and `{` characters: the page is rendered through MDX,
  which treats them as markup.
- Do not put LAN IPs, credentials, or stream URLs in entries. Make, model, and
  settings are all a reader needs.
