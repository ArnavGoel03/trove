# Permission bypass — expires 2026-06-06

On **2026-05-16** the user opted into global `bypassPermissions` mode for
Claude Code (~/.claude/settings.json). This means every tool call across
**every project** auto-approves with no prompt — including destructive
ones — until reverted.

## Revert by 2026-06-06

Run **one** of:

```bash
# Option A — flip global back to default (still allows the scoped Trove
# allowlist in .claude/settings.local.json to apply).
python3 -c '
import json, pathlib
p = pathlib.Path.home() / ".claude/settings.json"
d = json.loads(p.read_text())
d.get("permissions", {}).pop("defaultMode", None)
d.pop("skipDangerousModePermissionPrompt", None)
p.write_text(json.dumps(d, indent=2) + "\n")
print("Bypass reverted. Project allowlist still applies.")
'
```

```bash
# Option B — open the global settings in your editor and remove
#   "permissions": { "defaultMode": "bypassPermissions" }
#   "skipDangerousModePermissionPrompt": true
$EDITOR ~/.claude/settings.json
```

## What stays after revert

`.claude/settings.local.json` in this repo still allowlists the workflow
commands you've already vetted (gh, git, build-macapp, test-trove,
lint-trove, ditto, defaults, plutil, mdfind, etc.), with explicit denies
for `rm -rf /`, `sudo`, `git push --force`, `git reset --hard`, and
`defaults delete -globalDomain`. So after you flip global back to
default, the Trove workflow keeps moving smoothly while genuinely new
commands still prompt.

## Calendar reminder

Set one for 2026-06-06. Nothing in Claude Code auto-expires bypass mode.
