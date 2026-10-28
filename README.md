# Clean Up Crew

A crew of OpenCode skills for Windows disk cleanup and safe maintenance.

The first skill, **`clean-up`**, audits disk usage, builds a cleanup plan, and deletes only after you approve that exact plan. It never force-kills processes and never works around administrator requirements.

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (included with Windows)
- OpenCode
- Optional: Node.js 18+ if you want to install with `npx skills`

## Install

### 1. Install the skill

```powershell
npx skills add peterhany4/clean-up-crew --skill clean-up -g -a opencode -y --copy
```

### 2. Install the `/clean-up` command

The skills CLI installs skills, not slash commands. The command template ships inside the installed skill:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\opencode\commands" | Out-Null
Copy-Item "$env:USERPROFILE\.config\opencode\skills\clean-up\command.md" "$env:USERPROFILE\.config\opencode\commands\clean-up.md" -Force
```

### 3. Restart OpenCode if needed

Then run `/clean-up` or ask OpenCode to "check C drive".

### Update later

```powershell
npx skills update clean-up -g
```

## What it does

- Reports free space, cleanup target sizes, top `LocalAppData` folders, top global npm packages, and growth trend.
- Builds a JSON plan for the target IDs you approve.
- Applies only that plan, re-checking paths and blocked processes at apply time.
- Handles blocked browser caches and admin-only targets without force-killing or escalating.
- Treats hibernation, pagefile changes, and app uninstalls as recommendations only (Tier 3).

## Safety model

- **Report** is read-only. With `-SaveHistory` it adds one local history record.
- **Plan** changes nothing. It records target IDs, current sizes, and blocked status.
- **Apply** requires explicit approval of the exact plan. The scripts re-expand paths from `references/targets.json`, re-check the path guard and blocked processes, and skip blocked items.
- The scripts never force-kill processes or work around administrator requirements.
- History lives at `%LOCALAPPDATA%\opencode-disk-cleanup\history.jsonl`. It is personal data and is not included in this repository.

## Manual install

If you do not want to use the skills CLI, download or clone this repository and run the following from the repository root:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\opencode\skills" | Out-Null
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\opencode\commands" | Out-Null
Copy-Item -LiteralPath .\skills\clean-up -Destination "$env:USERPROFILE\.config\opencode\skills\clean-up" -Recurse -Force
Copy-Item -LiteralPath .\skills\clean-up\command.md -Destination "$env:USERPROFILE\.config\opencode\commands\clean-up.md" -Force
```

If the repository was downloaded as a zip, unblock it first:

```powershell
Get-ChildItem -LiteralPath . -Recurse -File | Unblock-File
```

Or right-click the zip, open Properties, select **Unblock**, then extract it.

## Verify

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\clean-up\tests\Test-Guardrails.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\clean-up\tests\Test-Apply.ps1
```

Expected: 13 guardrail passes and 14 apply passes. The apply test uses a temporary fixture and restores `targets.json` and the local history file.

## Repository layout

- `skills/clean-up/SKILL.md` - workflow and safety rules.
- `skills/clean-up/command.md` - `/clean-up` slash command template.
- `skills/clean-up/references/targets.json` - allowlisted cleanup targets.
- `skills/clean-up/scripts/` - report, plan, apply, and trend scripts.
- `skills/clean-up/tests/` - guardrail and end-to-end tests.

## Customizing

Add or remove targets in `skills/clean-up/references/targets.json`. Keep the required fields and run both tests after edits.

The skill targets the Windows system drive and uses `%SystemRoot%`, `%LOCALAPPDATA%`, and `%SystemDrive%`, so it adapts to the system drive letter.

## More skills

The `clean-up` skill is the first member of the crew. New Windows maintenance skills can live under `skills/` without changing the install command for existing skills.

## License

MIT. See [LICENSE](LICENSE).
