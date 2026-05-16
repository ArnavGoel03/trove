# Trove Privacy Policy

**Effective date:** 2026-05-11
**Contact:** yashgoel0304@gmail.com

## Summary in one sentence

Trove runs entirely on your Mac. It does not send your data anywhere, does not analyze your usage, does not include analytics SDKs, and does not phone home. The only network request it makes is to **www.ecb.europa.eu** for daily exchange rates (no identifying information attached).

## What Trove stores, where, and why

| Data | Where | Why | Lifetime |
|---|---|---|---|
| Stage items (text, images, file references) | In memory + temp files in `/tmp/trove-…/` | Run the multi-clipboard staging feature | Cleared on quit; macOS auto-cleans `/tmp` |
| Clipboard history entries | In memory only | The History pane | Cleared on quit |
| Snippets | `~/Library/Application Support/Trove/snippets.json` | Persist your saved text templates across launches | Until you delete them |
| Notes (5 colored tabs) | `~/Library/Application Support/Trove/notes.json` | Persist scratchpad content | Until you delete them |
| Sidebar visibility | `~/Library/Application Support/Trove/sidebar.json` | Remember which tools you've hidden | Until you re-show them |
| Storage scan cache | `~/Library/Application Support/Trove/storage-cache.json` | Show last scan instantly on relaunch | Refreshed when you rescan |
| Exchange rate cache | `~/Library/Application Support/Trove/exchange.json` | Currency conversions in the Calculator | Refreshed every 24h |
| Sign in with Apple identity token | macOS Keychain (`com.arnavgoel.trove`) | If you choose to sign in via Apple in the Account pane | Until you sign out |
| Sign in with Apple name / email | `~/Library/Application Support/Trove/account.json` | Display your name on the Account pane | Until you sign out |

Everything is in your home directory or your Keychain. Trove never copies it anywhere else.

## Network behavior

Trove makes exactly one kind of network request:

- **What:** A GET request to `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml` to download the European Central Bank's daily reference rates feed.
- **When:** On first launch, and at most once per 24 hours after that, only when the local cache is stale.
- **What is sent:** A standard `URLSession` request with the default user agent. No identifying headers, no account info, no usage info. The ECB's response is a small XML file.
- **What is received:** Daily reference rates for ~30 currencies (per-EUR).

No other network request happens anywhere in the app. You can verify this by running Little Snitch or a similar tool, or by inspecting the source.

## Permissions Trove may request

macOS will prompt you to allow these the first time you use the relevant feature. You can revoke any of them at any time in **System Settings → Privacy & Security**.

| Permission | Required for | Used how |
|---|---|---|
| Accessibility | Snap, Switcher, Move Files | Move/resize windows; intercept ⌘X / ⌘V keystrokes when Finder is frontmost |
| Screen Recording | OCR, Recorder | Capture a region or the screen for text recognition or recording |
| Microphone | Recorder (mic toggle) | Record audio alongside the screen recording |
| Apple Events (Finder) | Move Files, Finder Tweaks | Read Finder's current selection / target folder; apply preference defaults |
| Files & Folders (Downloads, Desktop, Documents, Photos) | Storage panes, Image Tools | Read sizes, list contents, organize Downloads |

Trove does not request any permission it doesn't actively use.

## Third-party SDKs

None. There are zero third-party libraries, analytics, crash reporting, or telemetry in Trove. The full source is a small set of Swift files compiled with `swiftc`.

## Children's privacy

Trove is not directed at children under 13 and does not knowingly collect any personal information.

## Updates to this policy

If anything material changes, the new policy will be available at the same URL with a newer effective date.

## Contact

Questions or concerns: yashgoel0304@gmail.com
