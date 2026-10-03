# Google Sheets — gotchas & reference

Cross-project. (The n8n Sheets *node* "Always Output Data" gotcha lives in n8n.md.)

## Gotchas

### Bulk runs hit the Sheets WRITE rate limit (429 RESOURCE_EXHAUSTED) → mid-batch failures
- Symptom: when a batch of leads is approved at once, n8n executions error with
  `429 ... Quota exceeded for quota metric 'Write requests' ... sheets.googleapis.com`. The lead's real
  work (CRM upsert, status write) already succeeded — it's the **audit-LOG append** that 429s, but it
  errors the whole execution and can **stop a poller's batch loop mid-run**.
- Cause: a burst of leads × several Sheet writes each (WF1 log + WF2 row-update + WF2 log + WF3 logs +
  Email-Log) all land within ~60s → trips the per-minute write quota. n8n Sheets nodes have **no retry**
  by default, and a 429 is a pre-write rejection (so retrying is safe — won't double-append).
- Fix (Outreach WF1/WF2/WF3 + Sub-Log-Drip-Send, 2026-06-23): on every Sheets node set **Retry On Fail**
  (3–4 tries, 3–4s backoff). On **non-critical LOG/append** nodes also set **onError =
  continueRegularOutput** (a log failure must never error/halt the lead). Keep **stopWorkflow** on
  **critical** nodes (read-leads, mark-Processed, suppression read) so they fail loud, not silent — and
  for mark-Processed specifically, it sits BEFORE the enroll step so a failure can't enroll-without-marking
  (which would re-pickup → double-send). Self-heals anyway: the next 15-min poll catches stragglers.
- Found: 2026-06-23 — a cold-outreach drip pipeline.

### A Sheets **503 "Service unavailable"** outlives ANY n8n retry budget — retry is the wrong layer
- Symptom: one lead sits in Wealthbox + Livestorm but never reaches `webinar-leads`. `#ops` shows
  "Workflow failed: Webinar — Form Pipeline / Failed at node: **Flag Append Failure**".
- **The failing node does NOT render red.** With `onError: continueErrorOutput` n8n considers the Sheets node
  *successful* — it just routes the item out its **second** output. The only red node is the downstream
  `stopAndError` tripwire, which is the reporter, not the fault. The Google error text lives as a payload on
  the node's **Error Branch** tab (OUTPUT panel), not on the node itself. Clicking the red node gets you the
  tripwire's own message echoed back and tells you nothing.
- Cause: Google returned **`Service unavailable - try again later`** (503) — a transient Google-side outage.
  The append had `retryOnFail: 4 × 3000ms` ≈ **12 s** of cover; the outage outlasted it.
  **NOT header drift** (the node is `autoMapInputData`, immune by design — that was the 2026-07-11 fix),
  NOT auth, NOT quota. Don't reach for the 429 playbook above; different code, different correct response.
- **You cannot retry your way out of a dependency outage.** n8n caps `maxTries` at 5 and `waitBetweenTries`
  at 5000 ms, so even a fully maxed node covers **~25 s**. Raise it (worth doing — absorbs short blips) but do
  not mistake it for a fix. The durable answer is **reconciliation**: a scheduled job diffing Wealthbox
  `src:webinar` contacts (or the Livestorm roster) against `webinar-leads` and flagging gaps. Same shape as
  the suppression-audit reconcile monitor <workflow-id>, different pair of systems.
- **Blast radius is wider than the missing row — check what else hangs off output 0.** The item exits on
  output 1, so everything on output 0 is skipped: `Mark Processed - Success` (the idempotency key is never
  stamped, so the contact is NOT locked out and can re-register) **and the entire Meta CAPI branch** (the
  server-side Lead event for a paid conversion never fires). **A Sheets outage silently degrades ad
  attribution.** Audit that coupling anywhere a terminal log gates CAPI.
- ✅ **FIXED 2026-09-21.** CAPI no longer hangs off the sheet at all: `Build CAPI Fields` now attaches to
  **`Respond 200 OK` as target [0]**, so the conversion is reported the moment the submission is accepted
  and is immune to Wealthbox, Livestorm *and* Sheets failures. `Mark Processed - Success` is now a
  terminal leaf — deliberately still gated on the append, so a failed log leaves the lead re-registerable.
  ⚠️ **Target [0] is load-bearing, not cosmetic** — n8n runs branches depth-first, so as target [1] the
  CAPI chain would still be skipped by a throw. See the depth-first gotcha in `n8n.md`.
- **Do not "just resubmit" the form to backfill** — a fresh submission mints a new browser `event_id`, so the
  CAPI event double-counts the conversion. Backfill the row by hand from the execution's `Build Webinar Row`
  output (JSON view), and accept the CAPI event as lost.
- **The alert could not name the lead.** `Flag Append Failure` built its message from `$json.Email`, but on an
  **error output** n8n replaces the item with the error payload — the field is gone, so it printed
  `unknown`. It told you to backfill without saying whom. Fix: reference the upstream node
  (`$('Build Webinar Row').first().json.Email`) — node references resolve against that node's own output and
  survive the error branch. Generalizable: **never build an alert message from `$json` on an error path.**
- Found: 2026-09-01 — a webinar registration pipeline.

### The 503 recurred 30h later at MAX retry — reconciliation is now built
- 2026-09-02 a second registrant was dropped (`lead@example.com`) with the identical
  `Service unavailable` 503 — **while already carrying the maxed `5 × 5000ms` retry** applied the day
  before. Two drops in 30 hours. This settles it: **retry is the wrong layer, at any setting.**
- ✅ The durable fix now exists and is live: **`Webinar — Lead Reconcile (Livestorm vs Sheet)`**, every 2h PT. **Compare against Livestorm, not Wealthbox** — the Form Pipeline
  registers in Livestorm *before* appending to the sheet, so "in Livestorm, not in `webinar-leads`" is
  the exact drop signature; Wealthbox `src:webinar` is broader and can't be scoped to one event.
- **Filter the roster or it cries wolf forever:** drop `role == 'team_member'`, `@company.example.com`
  and `+test`/`zz` addresses. Livestorm's raw roster included **a co-host registered as a normal `participant`** — a permanent false positive if unfiltered.
- Livestorm read: `GET /v1/sessions/{id}/people` (cred `Livestorm API`) →
  `{ data:[{ attributes:{ email, role, … } }], meta:{ record_count, page_count } }`.
- **The alert was verified on BOTH paths by real executions** — quiet (Slack correctly silent) *and* firing (a forced run with labelled synthetic data, Slack `ok:true`). Shipping an
  untested alarm is the exact failure this workflow exists to prevent.
- Found: 2026-09-03 — an estate-wide audit.

## Reference (stable facts)

- Prefer a **service account** for unattended automation: create it, download the
  JSON key, share the Sheet with the service-account email as Editor. Cleaner than
  OAuth.
- Intake patterns that worked: ARRAYFORMULA-driven Lead ID, dropdown validation,
  conditional formatting, a **protected range** on the approval column locked to the
  owner, and an `onEdit` auto-stamp trigger.
- Scaffold the whole sheet with one idempotent Apps Script so it's repeatable.
