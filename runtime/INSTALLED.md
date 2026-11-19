# cooked

Windows notifications for Claude Code, installed by [/cooked](https://github.com/dihannahdi/cooked).
Everything it needs is in this folder. The skill that set it up is not needed any more.

## What's here

| File | What it is |
| --- | --- |
| `config.json` | Sound, the minimum turn length for a "done" toast, the quiet rules. Edit freely. |
| `copy.json` | Every line of wording. Edit freely; keep `{session}` in titles and `{tool}` in permission bodies. |
| `notify.ps1` | Runs on Claude Code's `Stop` and `Notification` hooks and shows the toast. |
| `cooked.exe` | Built from `cooked.cs` on your machine. Opens the right tab on click, times each prompt, plays the sound. |
| `cooked.ps1` | `test`, `install -Voice ...` (change voice or sound), `uninstall`. |
| `voices/` | The bundled voices. |
| `.state/notify.log` | Why each toast did or didn't show. |

## Hooks it added to Claude Code's settings.json

`Stop` and `Notification` run `notify.ps1`; `UserPromptSubmit` runs `cooked.exe --mark`.

## Change something

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\cooked\cooked.ps1" test
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\cooked\cooked.ps1" install -Voice gaul
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\cooked\cooked.ps1" install -Sound "C:\path\to\sound.mp3"
```

## Remove it

Ask Claude Code: "uninstall cooked". Or by hand:

1. `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\cooked\cooked.ps1" uninstall`
   removes this folder, the `cooked:` link handler and the "Claude Code" notification identity (both per-user registry keys).
2. In `~/.claude/settings.json`, delete the three hook entries whose command mentions `cooked`.
