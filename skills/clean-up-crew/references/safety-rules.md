# Safety rules

## Consent model

1. **Report** is read-only. It measures sizes and, with `-SaveHistory`, appends one history record. `-DeepScan` also walks the drive for review-only large files and old installers.
2. **Plan** is read-only. It resolves allowlisted targets, measures current sizes, and records blocked status. It does not delete and does not run the path guard. `-Preset recommended` selects every tier-1 target except `recycle-bin`; `-AllTier1` includes it.
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

The guard checks each planned target path. Wildcards in `targets.json` are expanded to concrete paths before the apply-time guard runs, so each matched path is checked. The guard does not independently screen every descendant, so do not add a target under a protected directory. `%SystemRoot%\Temp`, `%SystemRoot%\SoftwareDistribution\Download`, `%SystemRoot%\Minidump\*.dmp`, `%SystemRoot%\LiveKernelReports\*.dmp`, and `%SystemRoot%\MEMORY.DMP` are the only allowlisted paths under `%SystemRoot%`; they are allowed by the allowlist, not by a general exception.

## Never

- Delete user files, project folders, git repositories, or game saves.
- Delete large files or old installers found by `-DeepScan`. They are review-only; the user decides manually.
- Delete `pagefile.sys`, `hiberfil.sys`, or `swapfile.sys` directly. Use the supported OS command and explicit consent.
- Run `DISM /ResetBase` automatically. It removes the ability to uninstall updates.
- Edit the registry, scheduled tasks, services, or firewall to "finish" a cleanup.
- Force-kill browsers or editors to unlock caches.
- Empty the Recycle Bin without approval; it is irreversible.

## Deletion mechanics

- `Remove-CleanupContents` deletes **children** of a target directory, never the directory itself.
- `Remove-CleanupFile` deletes only the exact file or wildcard match. It never recurses into a matched directory.
- Wildcard paths are expanded immediately before measuring, planning, and applying. A match that no longer exists at apply time is skipped.
- Exclusions are resolved to full paths and compared case-insensitively against direct children.
- Locked files are skipped and reported; they are not retried aggressively.
- Every planned filesystem target path is re-validated during apply, not only when the plan was built.
- `Invoke-Cleanup.ps1` ignores the `paths` recorded in the plan and re-expands paths from `targets.json`. Do not edit that file between plan and apply.

## System tools

- Prefer `DISM /Online /Cleanup-Image /AnalyzeComponentStore` for reporting.
- `StartComponentCleanup` is tier 2; it can take 10-30 minutes.
- `dism-component-cleanup` has no per-target byte estimate; the report shows 0 bytes. Use `-IncludeDism` for component-store analysis.
- Windows Update and Delivery Optimization caches are safe to clear but need admin; pending updates may download again.
- Windows crash dumps (`MEMORY.DMP`, `Minidump`, `LiveKernelReports`) are tier 2 because deleting them loses diagnostic evidence.
- Use Storage Sense or `cleanmgr` as OS-native alternatives when appropriate. `Windows.old` is recommendation-only; use Settings > System > Storage or Disk Cleanup.
- Do not hand-delete inside `WinSxS`.

## Reporting honesty

- Report measured bytes, not estimates.
- Per-item `freedBytes` is measured for file-based targets. Recycle Bin and DISM report 0 per item; use the net free-space delta.
- Deep-scan results are not cleanup targets. Report them separately and never add them to the cleanup total.
- Some "freed" space may be offset by servicing or application writes; show the net free-space delta.
- Hardlinks, sparse files, and junctions can make logical sizes differ from disk usage. Do not promise the logical total.
- If a cleanup frees less than expected, say so and stop. Do not escalate.
