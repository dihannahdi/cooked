# Contributing to cooked

Thanks for wanting to help. cooked is small on purpose: one PowerShell entry point
(`runtime/cooked.ps1`), one hook script (`runtime/notify.ps1`) and one small C# helper
(`runtime/cooked.cs`). Changes that keep it that small are the easiest to merge.

## Good places to start

- **A voice in your language.** This is the easiest first contribution: one JSON file, no code.
  See [Add a voice](#add-a-voice) below, and claim your language on [#1](https://github.com/dihannahdi/cooked/issues/1).
- **macOS or Linux.** cooked is Windows-only because it uses Windows notifications. If you want it
  on your machine, [#2](https://github.com/dihannahdi/cooked/issues/2) (macOS) and [#3](https://github.com/dihannahdi/cooked/issues/3) (Linux) say what each part does today and
  what a port needs.
- **Click-to-tab in more terminals** ([#4](https://github.com/dihannahdi/cooked/issues/4)). A click switches tabs only in Windows Terminal
  today. Other terminals just get their window brought to the front.
- **Bugs.** Open an issue with what you expected, what happened, and the last lines of
  `~/.claude/cooked/.state/notify.log`. That log says why each notification did or didn't show.

## Add a voice

1. Copy `voices/english.json` to `voices/<name>.json`, for example `voices/spanish.json`.
2. Rewrite every line the way you'd text a friend who's waiting on the same thing. Keep these:
   - The first two or three words say whether Claude is done or needs you. The two must never
     read alike.
   - Every title contains `{session}`, and stays within 38 characters, counting `{session}` as 10.
   - Every permission body contains `{tool}`.
   - Say what happened. No teasers, no emoji besides the two prefixes.
   - Change `_readme` to name the voice, like "Casual Spanish."
3. Check it:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File runtime/cooked.ps1 validate -Voice spanish
   ```

4. Open a pull request with a screenshot of one done notification and one permission one.

Setup picks up new voices on its own, so nothing else needs to change.

## Try a change end to end

Fork and clone the repo, then ask Claude Code:

```
Follow SKILL.md in <path to your clone>
```

It installs from your clone, exactly as a user would get it, and sends a test notification. Run
`/cooked test` (or `runtime/cooked.ps1 test`) to see a notification again after an edit. To go
back to the released version afterwards, run setup again from this repo.

## What cooked promises its users

A pull request that breaks one of these won't be merged, however useful it is:

- **Nothing leaves the computer.** No network calls and no telemetry.
- **No admin rights.** Everything is per user.
- **Nothing extra to install.** It runs on what ships with the operating system.
- **Quiet by default.** A notification you didn't need is worse than none.
- **Fast hooks.** They run on every turn, so a slow hook slows down Claude Code itself.

## Pull requests

- For anything bigger than a voice or a small fix, open an issue first, so we agree on the shape
  before you build it.
- One change per pull request. Say what you tested, and on which Windows version.
- Write plainly, in the README and in anything a user will read.

By contributing, you agree that your work is released under the [MIT License](LICENSE).
