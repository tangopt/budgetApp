# Step 19: import bank statements on the iPad (shared import lease) — design

Status: 2026-10-28. User (2026-10-27): iPad bank statement import with the shared import lease, including member
handoff. Calls marked *(my call)*; written unattended for the user to review. Budget ~2%.

## Behaviour
- On the iPad, a BBVA (or any supported) statement PDF/CSV — from Sites & downloads, Files, or Safari share-back —
  can be **imported on the iPad** instead of only being sent to the Mac's waiting list. Same review as the Mac:
  account, date range, rows found, duplicates skipped, then **Import** (explicit button).
- **One device imports at a time:** before import the iPad takes the household **import lease** (sync spec §5.2):
  writes importRun + SyncBatch like the Mac's ImportApplier, behind SyncImportGate.require. Needs to be online.
- While another device holds the lease, Import is disabled with "The Mac is importing (started 10:42). Try again
  when it finishes." The lease expires on its own after a timeout *(my call: 10 min, renewed while importing)* so a
  crashed device never blocks the household.
- **Member handoff:** a member (Patricia) whose access area allows imports for that account can import; one whose
  area does not gets "Send to the Mac" instead, which is today's behaviour (the statement goes to the Mac's waiting
  list). The owner can also hand an in-progress iPad statement to the Mac ("Finish on the Mac") *(my call)*.
- After import, documents waiting for that statement auto-link like on the Mac (step 9 rules: new transactions only).
- The Mac shows imports made on the iPad in its import history with the device name; Undo import works from either.

## Constraints
Logic (parsing, dedupe, lease, apply) in BudgetCore/MangoSync shared with the Mac — no second import engine; writes
via DeviceWriter with actor and filed-year checks; filed SA years unchanged; offline → "Connect to the internet to
import"; tests for lease contention, expiry, member without access, duplicate rows; iPad fits all sizes, no figure
wraps.

## Non-goals
iPhone import; new bank formats.
