---
description: Check Windows disk usage and clean approved caches safely
---

Load the `clean-up-crew` skill with the `skill` tool. The skill is authoritative for safety, targets, and script behavior. This command maps the user's arguments to one step of that workflow.

User arguments: `$ARGUMENTS`

## Routing

| Arguments | Action |
|---|---|
| empty, `report`, `status` | Run `Get-DiskReport.ps1 -SaveHistory`; present the report. Do not create a plan. |
| `trend` | Run `Get-Trend.ps1 -Last 8`; summarize growth and runway. |
| `targets`, `list` | List target IDs from the skill's `references/targets.json` with tier, name, and risk. Read-only. |
| `plan <id> [<id> ...]` | Run `New-CleanupPlan.ps1 -Items <ids> -OutFile "$env:TEMP\clean-up-crew-plan.json"`; show the plan. Stop. |
| `plan tier1` | Run `New-CleanupPlan.ps1 -AllTier1 -OutFile "$env:TEMP\clean-up-crew-plan.json"`; show the plan. Stop. |
| `dry-run [plan-path]` | Run `Invoke-Cleanup.ps1 -PlanFile <path>` without `-Apply`. Default path: `$env:TEMP\clean-up-crew-plan.json`. |
| `apply [plan-path]` | Only with explicit approval of that exact plan; run `Invoke-Cleanup.ps1 -PlanFile <path> -Apply`. Default path: `$env:TEMP\clean-up-crew-plan.json`. |
| bare target IDs | Treat as `plan <ids>`. |

If `<plan-path>` is omitted for `dry-run` or `apply`, use `$env:TEMP\clean-up-crew-plan.json`. If that file does not exist, run `plan` first; do not guess target IDs. If the request is ambiguous, ask one question. Do not infer approval from a prior "ok", "go ahead", or "clean it" that was not tied to a shown plan.

## Non-negotiable rules

- For a new cleanup, report first unless the user named specific target IDs. Never plan and apply in one step.
- Approval must identify the plan (plan ID, or the exact target IDs/tier and sizes shown in this conversation). "Clean everything" is not approval.
- Never pass `-Apply` without that approval.
- Never edit the skill's `references/targets.json` to bypass a block or to add a path.
- Never force-kill a process. If a browser or other listed process is running, report it and ask the user to close it.
- Never work around an administrator requirement or retry with elevation silently.
- Recycle Bin cleanup is irreversible; say so before asking for approval.
- If a plan is older than one hour, regenerate it. Do not reuse a stale plan.
- After an apply, stop. Report the result; do not chain another deletion.

## Response shape

1. **Report**: free GB and percent, target table, largest consumers, trend, recommendations.
2. **Plan**: plan ID, target IDs with measured size and status, blocked reasons, what will regrow, explicit approval question.
3. **Apply result**: per-item freed bytes where measured, net free-space delta from `freeBeforeGB`/`freeAfterGB`, failures and skipped items, any immediate regrowth.
4. **Trend**: free-space change per week and runway to 2 GB.

Keep it compact. Distinguish measured bytes from estimates and net free-space change from measured deletions.
