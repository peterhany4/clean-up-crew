# Safety rules

## Consent model

1. **Report** is read-only. It measures sizes and, with `-SaveHistory`, appends one history record.
2. **Plan** is read-only. It resolves allowlisted targets, measures current sizes, and records blocked status. It does not delete and does not run the path guard.
3. **Apply** requires explicit approval of the exact plan in the current conversation. Approval must identify the plan (plan ID, or the target IDs/tier and sizes that were shown). "Clean everything" is not approval.
4. **Tier 3** actions (hibernation, pagefile, app uninstalls) are not targets in `targets.json` and are never performed by these scripts. They need separate, explicit consent and usually a different tool.

`Invoke-Cleanup.ps1 -Apply` rejects plans older than one hour. It re-checks blocked processes and admin state at apply time. It cannot detect a restart or a change to `targets.json`; treat approval as stale after either and regenerate the plan.

## Protected paths

The allowlist in `targets.json` is the primary control. The path guard is defense in depth.

`Test-SafePath` rejects:

- drive roots (`C:\`)
- these exact paths: `%SystemRoot%`, `System32`, `SysWOW64`, `WinSxS`, `servicing`, `Installer`
- `Program Files`, `Program Files (x86)`, `ProgramData`
- the user profile root and `Desktop`, `Documents`, `Downloads`, `Pictures`, `Videos`, `Music`, `OneDrive`
- `%LOCALAPPDATA%` and `%APPDATA%` roots
- `%USERPROFILE%\.ssh`, `%USERPROFILE%\.config`
- any path containing `..`
- a target path that is itself a reparse point
- any path shallower than three segments

The guard checks each planned target path. It does not independently screen every descendant, so do not add a target under a protected directory. `%SystemRoot%\Temp` is the only allowlisted target under `%SystemRoot%`; it is allowed by the allowlist, not by a general exception.

## Never

- Delete user files, project folders, git repositories, or game saves.
- Delete `pagefile.sys`, `hiberfil.sys`, or `swapfile.sys` directly. Use the supported OS command and explicit consent.
- Run `DISM /ResetBase` automatically. It removes the ability to uninstall updates.
- Edit the registry, scheduled tasks, services, or firewall to "finish" a cleanup.
- Force-kill browsers or editors to unlock caches.
- Empty the Recycle Bin without approval; it is irreversible.

## Deletion mechanics

- `Remove-CleanupContents` deletes **children** of a target directory, never the directory itself.
- Exclusions are resolved to full paths and compared case-insensitively against direct children.
- Locked files are skipped and reported; they are not retried aggressively.
- Every planned target path is re-validated during apply, not only when the plan was built.
- `Invoke-Cleanup.ps1` ignores the `paths` recorded in the plan and re-expands paths from `targets.json`. Do not edit that file between plan and apply.

## System tools

- Prefer `DISM /Online /Cleanup-Image /AnalyzeComponentStore` for reporting.
- `StartComponentCleanup` is tier 2; it can take 10-30 minutes.
- `dism-component-cleanup` has no per-target byte estimate; the report shows 0 bytes. Use `-IncludeDism` for component-store analysis.
- Use Storage Sense or `cleanmgr` as OS-native alternatives when appropriate.
- Do not hand-delete inside `WinSxS`.

## Reporting honesty

- Report measured bytes, not estimates.
- Per-item `freedBytes` is measured for file-based targets. Recycle Bin and DISM report 0 per item; use the net free-space delta.
- Some "freed" space may be offset by servicing or application writes; show the net free-space delta.
- Hardlinks, sparse files, and junctions can make logical sizes differ from disk usage. Do not promise the logical total.
- If a cleanup frees less than expected, say so and stop. Do not escalate.
