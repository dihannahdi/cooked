---
name: cooked
description: >-
  One-time setup for Windows notifications from Claude Code. A toast with the session's name pops
  up when a turn is done (with how long it cooked) or when Claude needs a permission or an answer;
  clicking it jumps back to that exact Windows Terminal tab. Own sound, own voice, silent while you
  are already watching that tab or in Do Not Disturb, optional push to your phone. Also changes,
  tests or removes an existing install.
when_to_use: >-
  "/cooked", "notify me when Claude is done", "desktop notification when Claude Code finishes",
  "ping me when it needs me", "toast when done", "kasih notif kalau udah kelar", "uninstall cooked",
  "/cooked test", "/cooked voice", "/cooked sound".
argument-hint: "[test | voice | sound | uninstall]"
allowed-tools:
  - Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/runtime/cooked.ps1"*)
---

# cooked

The person wants to send a prompt, walk away, and get pinged when Claude is cooked or stuck. This
is the only time they will deal with setup, so: move fast, ask everything in **one** dialog, don't
make them read, and finish with a real toast on their screen.

`$SKILL` below is the folder holding this file: `${CLAUDE_SKILL_DIR}` when loaded as a skill, or
the folder you cloned if you were pointed at this file directly. Every command is:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL/runtime/cooked.ps1" <action> [flags]
```

Each action prints JSON. After install, the same script also lives at `~/.claude/cooked/cooked.ps1`.

## 0. Route

- Not Windows (`platform` isn't `win32`): say in one line that cooked is Windows-only for now
  because it uses Windows toasts, and stop. No workarounds.
- Argument `uninstall`: go to §6. `test`: run `test`, report in one line. `voice` or `sound`: ask
  only that question from §2, run `install` with only that flag, then `test`.
- Otherwise run `check` (§1). If `installed` is true, ask one question (Change voice / Change sound
  / Send a test / Uninstall) and do that. If not, set up (§1 to §5).

## 1. Preflight

Run `check`. Stop with a one-line fix when:

- `supported` is false: cooked needs Windows 10 or 11.
- `compiler` is false: .NET Framework 4.x is turned off. Fix: "Turn Windows features on or off",
  enable ".NET Framework 4.8 Advanced Services".
- `toasts_enabled` is false: notifications are off for the whole system (Settings > System >
  Notifications). Offer to continue anyway.

Remember `windows_terminal`. When false, a click focuses the terminal window but cannot pick a
tab; mention it once in the report, nowhere else.

## 2. One dialog

One AskUserQuestion call, four questions. Short labels, trade-offs in the descriptions.

1. **Voice** (header `Voice`). One option per file in `$SKILL/voices/` except `custom.json` (each
   file's `_readme` names it), then `My own voice`. Put first, marked (Recommended), the one matching the
   language the user writes to you in. Four options at most, so leave out shipped voices in
   languages the user doesn't use. Each description shows that voice's first done and permission
   titles, like these:
   - `Casual English`: "✅ fix-login is cooked" / "✋ fix-login needs your ok"
   - `Bahasa gaul`: "✅ fix-login udah kelar nih" / "✋ butuh izin nih di fix-login"
   - `My own voice`: Claude writes every line from how you actually type.
2. **Sound** (header `Sound`): `Windows default (Recommended)`, `My own file` (mp3, wav or wma;
   you'll be asked for it next), `Silent`.
3. **Done ping** (header `Done ping`): `Only turns of 30s+ (Recommended)`, `Only turns of 60s+`,
   `Every turn`. Description: toasts for permissions and questions always fire.
4. **Phone** (header `Phone`): `No (Recommended)`, `Yes, push to my phone`. Description: turns on
   Claude Code's Remote Control at every start so the Claude app can push when Claude needs you,
   and lets Claude push when a long task finishes. Sessions become reachable from claude.ai under
   your account. Needs the Claude app on your phone.

Follow-ups, only when needed:

- `My own file`: ask in plain text, "Drag the sound file into this window and press Enter." Strip
  quotes. If it isn't mp3, wav or wma, say so and use the Windows default.
- `My own voice`: §3.

## 3. My own voice

Samples, either way:

- Offer to learn from their last ~60 prompts in `~/.claude/history.jsonl`, which stay on this
  machine (yes / "I'll paste a few messages instead"). Use each line's `display` field; skip slash
  commands, pasted blobs and anything over 300 characters.
- Or ask them to paste 3 to 5 messages they'd send a teammate.

Read `$SKILL/voices/english.json` for the shape, then write `$SKILL/voices/custom.json` with the
same keys. Rules, in priority order:

1. State first. From the prefix glyph and the first two or three words, the reader knows "done"
   or "needs you". The two sets must never read alike.
2. `{session}` in every title. Titles stay within 38 characters, counting `{session}` as 10.
3. Their voice: their casing, particles, slang, code-switching and pronouns, as a friend talking,
   not a brand mascot. No emoji besides the fixed prefixes.
4. Say what happened. No teasers ("guess what!").
5. Every permission body contains `{tool}`, untranslated.
6. `test_body`: one line telling them to click the toast from another tab.

Run `validate -Voice "$SKILL/voices/custom.json"` and fix until `ok`. Don't ask for approval;
show three sample toasts in the report instead.

## 4. Install, hook up, test

1. `install -Voice <voice file name without .json, e.g. english | "$SKILL/voices/custom.json"> -Sound <default | none | "path">
   -MinSeconds <30 | 60 | 0>`. The output's `hooks` holds the exact command for `Stop`,
   `Notification` and `UserPromptSubmit`; `settings` is the settings.json to edit.
2. Merge into that settings.json (create it as `{}` if missing). Read it, then Edit:
   - Under `"hooks"`, for each of the three events: if a hook command there already mentions
     `cooked\notify.ps1` or `cooked/cooked.exe`, replace only that command string. Otherwise append
     a group `{ "hooks": [ { "type": "command", "command": "<cmd>", "timeout": 15 } ] }`
     (`"timeout": 5` for `UserPromptSubmit`). No matcher.
   - Keep every other hook, key and the file's formatting.
   - If another hook already shows desktop notifications on `Stop` or `Notification`, say they'd
     get two toasts and ask whether to remove the old one.
   - Phone = yes: also set top-level `"remoteControlAtStartup": true`,
     `"inputNeededNotifEnabled": true` and `"agentPushNotifEnabled": true`.
   - Validate: `powershell -NoProfile -Command "Get-Content '<settings>' -Raw | ConvertFrom-Json | Out-Null; 'ok'"`.
     A broken settings.json silently disables all of their settings, so fix it before going on.
3. `test`: a real toast with the sound, right now. `ok: true` means Windows accepted it.
4. If `$SKILL` is a temporary clone (not under `~/.claude/skills`), delete it. cooked now lives
   entirely in `~/.claude/cooked`.

## 5. Report

In the user's language, like a friend confirming it's done. At most five short lines, plus the
three sample toasts for a custom voice:

- It's on: ✅ when a turn of 30s+ is done (use their choice), ✋ when Claude needs them. Click one
  to jump back to its tab.
- It stays quiet while they're on that tab, during Do Not Disturb, and for quick turns.
- "Didn't see the test toast? Tell me." (then §7)
- Phone = yes: the Claude app must be signed in to the same account; sessions already open need
  `/remote-control`.
- Change anything: `~/.claude/cooked/config.json` and `copy.json`. Remove: say "uninstall cooked".

No file lists, no internals unless asked.

## 6. Uninstall

1. `uninstall`, from `$SKILL` or, if the skill is gone, `~/.claude/cooked/cooked.ps1`.
2. In settings.json, remove the hook entries whose command mentions cooked. Drop a group left with
   no hooks and an event left with no groups. Ask before turning off the three phone keys; they
   may predate cooked.
3. Validate settings.json. Report in one line.

## 7. If something's off

- No toast at all: Settings > System > Notifications on, "Claude Code" in the app list on, Do Not
  Disturb off. Run `test` again and read the last lines of `~/.claude/cooked/.state/notify.log`.
- Toast but no sound: check `sound` in `config.json`. Do Not Disturb, fullscreen apps and
  presentations mute it on purpose; the log then says `muted`.
- No toast after a turn: the log says why (quick turn, you're on this tab, no new turn). That is
  the quiet rules working.
- Click doesn't jump: read `~/.claude/cooked/.state/click.log`. Tab switching needs Windows
  Terminal; elsewhere the click focuses the window.
- Hooks never fire: open `/hooks` once (it reloads settings) or restart Claude Code.
