# Disk report template

Use measured values from `Get-DiskReport.ps1`. Do not fill gaps with estimates.

## Status

- Drive: `C:`
- Free: `X.XX GB` (`XX.X%`)
- Change since last check: `+/-X.XX GB` (from history; `n/a` on first run)

## Cleanup targets

| ID | Tier | Size | Status |
|---|---|---:|---|
| npm-cache | 1 | 0.00 GB | ready |
| chrome-cache | 1 | 0.00 GB | blocked: Chrome running |

Status values come from the report: `ready`, `empty`, or `blocked: <reason>`. DISM may show `empty` because it has no byte estimate.

## Largest consumers

| Item | Size | Notes |
|---|---:|---|
| Hibernation file | 0.00 GB | trade-off; exact size may need admin |
| Pagefile | 0.00 GB | system-managed |
| Component store (actual) | 0.00 GB | `-IncludeDism`; admin required |
| App or package | 0.00 GB | review |

## Trend

- Growth: `X.XX GB/week`
- Runway to 2 GB free: `X weeks` (`n/a` if stable or increasing)

History includes apply records, so a large cleanup can skew the rate.

## Recommended actions

1. Tier 1 cleanup: `X.XX GB` — requires approval.
2. Tier 2 component cleanup: analyze with `-IncludeDism` — requires admin.
3. Tier 3 structural: hibernation, apps, pagefile — separate decisions.

## Applied result

| ID | Freed | Status |
|---|---:|---|
| npm-cache | 0.00 GB | completed |

Per-item freed bytes are measured for file targets. Recycle Bin and DISM show 0 per item.

Status values: `completed`, `completed with errors`, `blocked: <reason>`, or `error: unknown target`.

Net free space: `X.XX GB -> X.XX GB` (`+/-X.XX GB`).
