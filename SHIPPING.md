# Shipping Trove

Everything to go from "the app runs on my Mac" to "anyone can download,
auto-update, and install it." Read top-to-bottom. The **Direct Distribution**
path is recommended.

There are **four pieces** in play:

1. `notarize-trove` — signs + notarizes + staples `Trove.app`, produces `Trove.zip`.
2. `build-trove-dmg` — packages the notarized app into a signed, stapled `Trove.dmg`.
3. `trove-appcast` — generates / appends a Sparkle appcast entry so the in-app updater finds the new version.
4. `trove-release` — runs all of the above, drafts release notes, and publishes a GitHub Release.

Together: one command per release.

---

## First-release setup (one-time, ≈45 min)

### 1. Apple Developer prerequisites

1. **Enroll in the Apple Developer Program** ($99/year)
   https://developer.apple.com/programs/enroll/ — wait for activation.

2. **Install your "Developer ID Application" certificate** in Keychain.
   Easiest path: Xcode → Settings → Accounts → Add Apple ID → **Manage Certificates → + → Developer ID Application**.
   No-Xcode alternative: generate a CSR in Keychain Access → upload at
   https://developer.apple.com/account/resources/certificates/list → download the `.cer` → double-click.

3. **Generate an App-Specific Password**
   https://appleid.apple.com → Sign-in & Security → App-Specific Passwords → Generate (name it "Trove notarization"). Save the `xxxx-xxxx-xxxx-xxxx` string — Apple won't show it again.

4. **Note your Team ID** (10 chars, e.g. `ABCDEF1234`):
   https://developer.apple.com/account → Membership Details.

Drop the three secrets into a sourceable env file (e.g. `~/.trove-release-env`):

```bash
export APPLE_ID="you@example.com"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export TEAM_ID="ABCDEF1234"
```

`chmod 600` it. Source it before each release: `source ~/.trove-release-env`.

### 2. Sparkle keys (for in-app auto-update)

```bash
brew install --cask sparkle          # installs `generate_keys` + `sign_update`
generate_keys                        # generates an Ed25519 keypair (stored in Keychain)
                                     # also prints the SUPublicEDKey — copy it
sign_update --export-private-key > ~/Documents/Projects/trove/macos/sparkle_ed_private_key
chmod 600 ~/Documents/Projects/trove/macos/sparkle_ed_private_key
```

Add the public key (from `generate_keys` output) to the app's `Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/USER/trove/main/appcast.xml</string>
```

(Or wherever you intend to host `appcast.xml`.)

### 3. GitHub setup

```bash
brew install gh
gh auth login
gh repo create USER/trove --public --source=. --remote=origin --push
```

If `trove-release` is run before the repo exists on GitHub, it bails out with an explicit "create the repo first" message — no silent failures.

### 4. (Optional) DMG background image

Drop a custom 540×380 PNG at `~/Documents/Projects/trove/macos/dmg-bg.png`. If it's missing, `build-trove-dmg` synthesizes a plain dark-gray placeholder automatically; if `sips` can't generate one, the DMG is built without a background (still works fine).

---

## Every-release workflow (one command)

```bash
source ~/.trove-release-env       # APPLE_ID / APP_PASSWORD / TEAM_ID
build-macapp ~/Documents/Projects/trove/macos ~/Applications/Trove.app com.arnavgoel.trove "Trove"
trove-release v1.2.3
```

That's it. `trove-release`:

1. Verifies `gh auth status` and that the GitHub repo exists.
2. Runs `notarize-trove` if `Trove.zip` isn't already built for this version.
3. Runs `build-trove-dmg` to produce a signed + notarized + stapled `Trove.dmg`.
4. Drafts release notes from `git log` (commits since the previous tag, or last 20 commits if there's no prior tag).
5. Calls `gh release create vX.Y.Z` and uploads both `Trove.zip` + `Trove.dmg`.
6. Runs `trove-appcast` to add a signed entry to `~/Documents/Projects/trove/macos/dist/appcast.xml`.
7. If the repo tracks `appcast.xml`, commits + pushes it so Sparkle clients see the update.

### What each script does individually (if you want to run them manually)

| Script | Purpose | Output |
|---|---|---|
| `notarize-trove` | Sign + notarize + staple the app | `~/Documents/Projects/trove/macos/dist/Trove.zip` |
| `build-trove-dmg [app-path]` | Stage app + /Applications symlink, hdiutil → UDZO, sign, notarize, staple | `~/Documents/Projects/trove/macos/dist/Trove.dmg` |
| `trove-appcast [--version X --asset Z.zip --repo USER/trove --notes "…"]` | Append a signed Sparkle entry | `~/Documents/Projects/trove/macos/dist/appcast.xml` |
| `trove-release vX.Y.Z` | All of the above + `gh release create` | GitHub Release + updated appcast |

Environment variables read by these scripts:

- `APPLE_ID`, `APP_PASSWORD`, `TEAM_ID` — required by `notarize-trove` and (for DMG notarization) `build-trove-dmg`.
- `TROVE_VERSION`, `TROVE_ASSET`, `TROVE_REPO`, `TROVE_NOTES` — optional overrides for `trove-appcast` (flag equivalents also accepted).

---

## Where users find the download

**Human-facing landing page**: the Vercel site (`trove-site` project) — designed for first-time visitors, links to the latest GitHub Release.

**Direct download**: GitHub Releases page — `https://github.com/USER/trove/releases/latest`. Users grab `Trove.dmg`, double-click, drag-to-`/Applications`, done. Gatekeeper accepts it because it's notarized + stapled.

**In-app auto-update**: Sparkle reads `SUFeedURL` (set in `Info.plist`, typically pointing at the `appcast.xml` hosted on GitHub raw or your own CDN). When a new release pushes a new entry, every installed copy of Trove prompts the user to update. EdDSA signature on each entry guarantees authenticity — even if the appcast host is compromised, an unsigned or wrongly-signed entry won't install.

---

## Mac App Store (alternative path — not recommended)

The Mac App Store requires App Sandbox, which disables ~half of Trove's features (Snap, Switcher, cut-paste-in-Finder, Processes, Storage Scan, Finder Tweaks all break). The entitlements file at `~/Documents/Projects/trove/macos/Trove-store.entitlements` and `#if !APPSTORE` guards are pre-staged if you ever change your mind. See the table at the bottom of this doc for the per-feature breakdown.

**Recommendation: skip MAS.** Direct Distribution keeps every feature, 100% of revenue (minus your payment-processor's cut), and Apple has no review/rejection veto.

| Feature | Sandbox status | Notes |
|---|---|---|
| Stage, History, Snippets, Notes | ✅ Works | |
| Calculator, Text Tools | ✅ Works | ECB rates need `network.client` |
| Color Picker | ✅ Works | Screen pick needs Screen Recording |
| QR | ✅ Works | |
| Image Tools, File Hash | ⚠ Partial | NSOpenPanel only |
| OCR / Recorder | ⚠ Partial | `temporary-exception.screen-capture` may be rejected |
| Snap (tiling) | ❌ Blocked | Cross-app AX blocked |
| Switcher (AltTab) | ❌ Blocked | Carbon hotkey + AX blocked |
| Move Files | ❌ Blocked | CGEventTap blocked |
| Finder Tweaks | ❌ Blocked | `defaults write` blocked outside container |
| Processes | ❌ Blocked | `kill()` blocked |
| Storage Scan/Clean/Sweep | ❌ Blocked | Broad FS access blocked |

---

## App icon

Already done. `~/Documents/Projects/trove/macos/icon.icns` is generated by `make-trove-icon`. `build-macapp` bundles it automatically.

## Privacy policy URL

`~/Documents/Projects/trove/macos/PRIVACY.md` is ready to publish — Gist, GitHub Pages, or your own site. Put the URL in the landing page footer.

## Listing copy

`~/Documents/Projects/trove/macos/APPSTORE-LISTING.md` has the name, subtitle, 4000-char description, keywords, category, "What's New", and screenshot guidance. Paste into your landing page / Gumroad / MAS listing.

---

## One-line checklist

```
[ ] Enroll in Apple Developer Program ($99)
[ ] Import Developer ID Application cert into Keychain
[ ] Generate App-Specific Password at appleid.apple.com
[ ] Note your Team ID
[ ] brew install --cask sparkle ; generate_keys ; export private key
[ ] Add SUPublicEDKey + SUFeedURL to Info.plist
[ ] brew install gh ; gh auth login ; gh repo create USER/trove
[ ] source ~/.trove-release-env
[ ] trove-release v1.0.0     # ← this is the only line for future releases
```
