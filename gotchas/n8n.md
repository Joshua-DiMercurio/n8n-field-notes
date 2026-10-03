# n8n — gotchas & conventions

Cross-project. Read before building any n8n workflow.

> **Shorthand.** `WF1`, `WF2`, `WF3` … are sequential workflows in one chain (a poller hands to
> a CRM upsert, which hands to an email enroll); `WF-A`, `WF-N1`, `WF-N2` are named stages in
> other chains. They are ordinals, not product names — several entries below turn on how a
> failure in one propagates to the next.

## Gotchas

### MCP `setNodeParameter` silently no-ops on a large Code-node `jsCode` — use `updateNodeParameters`
- Symptom: `update_workflow` with a `setNodeParameter` op on `/parameters/jsCode` returns
  `appliedOperations: N` (success), but the Code node body is UNCHANGED at runtime. Other ops in the
  same batch (e.g. `addNode`) DO persist — so it is not a total failure, which makes it easy to miss.
- Cause: `setNodeParameter` (JSON-pointer path) does not reliably write a large multi-line string into
  `parameters.jsCode`; the op reports success regardless.
- Fix: use **`updateNodeParameters`** (`replace: false`, `{ parameters: { jsCode: "…" } }`) — the
  merge-parameters op writes the full body correctly. Same for any large expression param (HTTP `jsonBody`).
- Verify by **execution**, never by the `appliedOperations` count: run the workflow (manual) and inspect
  the node's actual output. `appliedOperations` counts ops attempted, not effects realized.
- Found: 2026-07-11 — an internal Slack ops digest.

### Full-size, in-channel Slack cards = `chat.postMessage` Block Kit image block, NOT the Slack node
- The Slack node v2.5 `file/upload` posts a *medium* card and does not reliably share to the channel
  (`channels: []`); `messageType: 'block'` + top-level `text` drops the blocks ("no_text").
- Fix that renders **full-width, in-channel**: an **HTTP Request node → `https://slack.com/api/chat.postMessage`**
  with `contentType: json`, `jsonBody` = `{ channel, text (fallback), blocks: [{type:'image',image_url,alt_text}, {type:'actions',elements:[…]}] }`,
  auth = a bot-token `httpHeaderAuth`/`httpBearerAuth` cred (MCP can't bind it — user picks it in the UI).
- The `image_url` is a public renderer (`/api/og/*`); Slack fetches it server-side. For a slow (animated
  GIF) renderer, **prime the URL with a GET node first** so Vercel's edge cache is warm before Slack fetches.
- Found: 2026-07-11 — an internal Slack ops digest.

### Server runs UTC, not Pacific
- Symptom: `setHours(10)` in a Code node scheduled things for 3 AM PT, not 10 AM.
- Cause: the n8n server clock is UTC.
- Fix: use `setUTCHours(17)` for 10 AM PDT (adjust for PST/DST).
- Found: 2026-06-10 — a multi-step email drip.

### Sheets "update" with no matching row silently kills the chain
- Symptom: downstream nodes just don't fire, no error.
- Cause: when the update key matches no row, the node outputs `[]`, so nothing
  flows downstream.
- Fix: enable **Always Output Data** in the node's Settings.
- Generalizable: any node whose empty output would strand a chain.
- Found: 2026-06-10 — a cold-outreach drip pipeline.

### Sheets append with `defineBelow` errors if the sheet headers drift from the cached schema
- Symptom: append fails with "Column names were updated after the node's setup. Refresh the
  columns list… Missing columns: X, Y." Every upstream node succeeded; only the Sheets append died.
- Cause: `mappingMode: defineBelow` caches the column schema at node setup. At runtime n8n compares
  it to the sheet's live header row; any mismatch (a header missing, renamed, or mistyped) throws.
  Building the node via SDK with a schema makes this worse — the schema can't be "refreshed" via API.
- Fix: use **`mappingMode: autoMapInputData`** + `options.handlingExtraData: 'insertInNewColumn'`,
  fed by a small **Set node** that emits exactly the columns you want (named to match the headers).
  Auto-map binds by header name at runtime (no cached schema) and self-adds any missing column.
  This is the pattern the working log-appends use (e.g. WF1 Build Log Entry → Append to Log).
- Found: 2026-06-18 — a weekly AI digest.
- **Amplifier — `onError: continueRegularOutput` turns this into SILENT lead loss.** If the drifted
  append node also has continue-on-error (the standard non-critical-append setting), the throw is
  swallowed, the execution still reports **success**, and the flow marches to `Mark Processed`. Result:
  every lead lands in the CRM but silently vanishes from the sheet — no error, no alert, for days. The
  tell-tale is "contact exists in Wealthbox but not in the tab." Diagnose via `get_execution` on the
  node (you'll see the "Missing columns: <HEADER>" error captured even though status=success). autoMap
  is the real fix; continue-on-error is fine *once* the drift can't happen.
- **Corollary — interleaved manual subtotal rows fight append; derive totals live instead.** A tab that
  the pipeline appends to CANNOT hold hand-placed "Total: N" divider rows in the middle: an n8n append
  always lands at the bottom of the used range, never inside a section, and non-date "Total:" rows also
  break any `QUERY` that reads the column. Keep the append target flat; add a grouping column (e.g.
  `Webinar Date`) and put per-group totals in a separate live `=QUERY(... group by ...)` tab that
  recomputes itself. (Same family as the whole-column-formula gotcha below.)
- Found again: 2026-07-11 — a webinar registration pipeline.

### Schedule Trigger cron uses America/New_York by default — NOT UTC
- Symptom: a "nightly 10 PM" logger (`0 5 * * *`, assumed to be UTC) actually fired at 2 AM
  Pacific. Slack posts arrived at odd hours.
- Cause: n8n evaluates Schedule Trigger crons in the workflow's timezone. With no timezone
  set on the workflow AND no `GENERIC_TIMEZONE` env var, n8n falls back to its built-in
  default **`America/New_York`** (Eastern), not UTC, not the system clock. Tell-tale: n8n's
  event-log timestamps come out in `-04:00`/`-05:00` even on a Pacific machine.
- Fix: set the timezone **per workflow** — `settings.timezone = 'America/Los_Angeles'` — then
  write the cron in that local time (`0 22 * * *` = 10 PM PT). Per-workflow avoids shifting
  every other workflow's schedule the way changing instance `GENERIC_TIMEZONE` would.
- Via API: PUT `/workflows/{id}` with `settings` containing ONLY allowed keys (`executionOrder`,
  `timezone`, …) — sending `binaryMode` or other GET-returned keys → 400 "must NOT have
  additional properties". PATCH isn't allowed; GET → strip → PUT.
- NOTE: this is separate from the Code-node `Date` UTC issue below — that's the Node *process*
  clock; this is the *cron's* timezone. They can disagree.
- Also: an in-process cron can't fire while a **laptop sleeps**, and n8n does NOT backfill the
  missed run on restart — it re-arms for the next future occurrence. On a sleeping Mac, pair the
  schedule with `pmset repeat wakeorpoweron` + a `caffeinate` LaunchAgent (idle sleep is often
  1 min, too short to bridge wake→run).
- Found: 2026-06-16 — a nightly logging workflow.

### Firing many nested executions at once deadlocks n8n cloud concurrency
- Symptom: a batch of 5 records approved → WF1 fired all 5 at once → each lead's WF2 synchronously calls WF3
  (webhook) which calls tracking sub-workflows. The WF2s stuck "running" holding every concurrency
  slot; the WF3s they spawned sat at "new" (never started) → self-deadlock. Worked fine 1-at-a-time.
- Cause: n8n cloud caps concurrent executions. A burst of nested webhook calls (WF1→WF2→WF3→subs)
  saturates the pool; parents hold slots waiting on children that can't get a slot.
- Fix: **throttle the fan-out.** Wrap the per-item hand-off in `splitInBatches` (batchSize 1) +
  a `wait` (e.g. 15s) loop so leads process sequentially, not in parallel. (WF1, 2026-06-17.)
- Recovery for an active jam: Stop the stuck parent executions in the UI to free slots; the queued
  children then run. Re-run the (now-throttled) poller for any still-unprocessed rows.
- Found: 2026-06-17 — a cold-outreach drip pipeline.

### Whole-column Sheet formula + append → rows land at the BOTTOM; reads miss them
- Symptom: WF0 synced new leads ("New: 7" logged) but they were invisible in Intake and the
  poller (WF1) never picked them up even when Approved.
- Cause: the Intake `Lead ID` column has a whole-column ARRAYFORMULA. Google treats those cells
  as "occupied" all the way down, so the Sheets **append** node lands new rows *below* the
  formula range (≈row 1000+), leaving a gap. AND the n8n Sheets **read** node defaults to
  `readRowsUntil: 'firstEmptyRow'` → it stops at the gap and never reaches the appended rows.
- Fix (band-aid, applied): set the read node's `options.dataLocationOnSheet.readRowsUntil` to
  **`lastRowInSheet`** so it reads the whole sheet (empties filter out downstream).
- Real fix (DONE 2026-06-17): removed the whole-column formula — froze the `Lead ID` column to
  values (Copy → Paste special → Values only), then **deleted** the empty formula rows (not just
  cleared — the ARRAYFORMULA emits `""` which Google counts as occupied; only a row delete shrinks
  the used range). Appends now land contiguously. The workflow writes `Lead ID` itself, so the
  formula was redundant.
- Reviewing data: use a **filter on a status column**, not scrolling — rows may be far down.
- Found: 2026-06-17 — a cold-outreach drip pipeline.

### Publishing a new version does NOT change already-running (waiting) executions
- Symptom: edited + published a new copy/signature into a long drip workflow, verified the change is live
  (`versionId == activeVersionId`, draft == active). Yet emails going out *today* still show the OLD copy —
  and, tellingly, a *later* drip email (e.g. Email 4) looks wrong while an *earlier* one (Email 2) looks
  correct.
- Cause: n8n pins each execution to the workflow snapshot that was live **when the execution started**. A
  publish only affects *new* executions. Waiting/in-flight executions (a multi-step drip parked between
  `wait` nodes) run to completion on their original version — even though the "Build Email N" Code node
  re-renders the HTML at send time, it re-renders using the *old* node code. So leads enrolled before the
  edit keep emitting the old copy for all their remaining steps; leads enrolled after get the new copy. A
  later-in-sequence email looking worse than an earlier one is the tell-tale (later email = enrolled earlier
  = older snapshot).
- Diagnosis: the working vs. broken emails will be **byte-identical** in the current live code — that rules
  out a code bug and points here. Confirm by pulling a pre-edit waiting execution (`search_executions`
  status=`waiting`, sort by oldest `startedAt`) and inspecting the HTML it actually sent
  (`get_execution` includeData) — it will lack the new content.
- Fix: there is **no safe retrofit**. n8n can't swap a waiting execution's version. Stopping + re-enrolling
  re-sends earlier emails (double-send). The correct move is usually **let the in-flight cohort drain** —
  new enrollments are already correct, and the base becomes uniform once the old cohort finishes. (Bonus:
  if the old copy is the previously-approved one, draining is also the safer choice.)
- Found: 2026-06-30 — a cold-outreach drip pipeline.

### Expression field auto-prepends `=`
- Symptom: JSON parse error at runtime.
- Cause: pasting `={{ ... }}` into a field already in expression mode stores a
  literal leading `=` → `={{ ... }}`.
- Fix: paste only `{{ ... }}` into expression-mode fields.
- Found: 2026-06-10.

### `&#39;` is the fix for HTML EMAIL bodies only — in Slack text it prints the entity RAW
- The apostrophe rule below is real but **output-format specific**. `&#39;` renders as `'` in an HTML
  email. Slack messages are plain text / mrkdwn, so the same escape lands in the channel verbatim:
  the alert read **"check that funnel&#39;s execution"** to a human.
- The underlying hazard is still there — a bare `'` terminates a single-quoted JS string inside a
  Code node — so the answer is not "use a bare apostrophe". **Reword to avoid one**, or use `\'`.
  Rewording is safer: it survives every layer (Python source → JSON → n8n expression → Slack) with
  nothing to escape.
- **Generalisable: ask what renders the string before escaping it.** The same body of text can pass
  through HTML, Slack, a sheet cell and a log line, and each wants something different.
- Found: 2026-09-17 — a CRM/sheet reconciler.

### Apostrophes stripped in SDK template literals
- Symptom: bare `'` terminates a JS string at runtime → SyntaxError.
- Cause: `\'` inside a TypeScript template literal gets stripped during SDK parsing.
- Fix: use HTML entities (`&#39;`) for apostrophes in body/HTML content. Survives
  the Python → TS template literal → JS runtime → HTML render chain.
- Found: 2026-06-10 — a cold-outreach drip pipeline.

### Built-in Node.js modules blocked in Code nodes by default
- Symptom: "Module 'child_process' is disallowed" (same for `fs`, `path`, etc.).
- Cause: n8n blocks all built-in modules in Code nodes unless explicitly whitelisted.
- Fix: add to `~/.n8n/.env` (then restart n8n):
  ```
  NODE_FUNCTION_ALLOW_BUILTIN=child_process,fs,path
  ```
- The wrapper script `~/.n8n/start-n8n.sh` sources `.env` so launchd picks this up automatically.
- Found: 2026-06-12 — a nightly logging workflow.

### REST API has no "run now" endpoint — manual trigger is browser-only
- Symptom: `POST /api/v1/workflows/{id}/run` and `/execute` both return "POST method not allowed".
- Cause: the v1 public API is management-only (CRUD + activate/deactivate). n8n has no HTTP
  endpoint to fire an ad-hoc execution of a schedule-triggered workflow.
- Fix: use the n8n browser UI (http://localhost:5678) → open the workflow → click "Execute
  Workflow". For automation, add a secondary Webhook trigger node and call that webhook via curl.
- Also: `PATCH` on workflows not allowed — use `PUT` with the full workflow JSON (GET first,
  modify in Python/JS, then PUT). `POST /workflows/{id}/activate` works fine.
- Found: 2026-06-12 — a nightly logging workflow.

### MCP `update_workflow` saves a DRAFT — you must `publish_workflow` to go live
- Symptom: edited WF3's email copy + a config constant via MCP `update_workflow`, "verified"
  by re-reading — but the live webhook kept running the OLD copy. A render test exposed it.
- Cause: n8n versions workflows. `update_workflow` writes a **draft** (`versionId`); the running
  version is `activeVersionId`. They differ until you **`publish_workflow`**. An *active* workflow
  keeps executing its last-published version, not your draft.
- Trap in verification: `get_workflow_details` → `.workflow.nodes` is the **DRAFT**. The live
  code is `.workflow.activeVersion.nodes`. Check `versionId == activeVersionId` to know if your
  edit is actually live, and verify against `activeVersion`, not `nodes`.
- Fix: after `update_workflow`, call `publish_workflow`, then confirm `versionId == activeVersionId`.
- **This applies to the go-live flip too:** editing `TEST_MODE = false` in WF3 Normalize Input
  does nothing until you publish. Edit → publish → verify active.
- Found: 2026-06-16 — a cold-outreach drip pipeline.

### `publish_workflow` on an ALREADY-ACTIVE webhook workflow can leave the runtime serving the OLD graph — deactivate→reactivate to flush
- Symptom: `update_workflow` + `publish_workflow` both returned success; `get_workflow_details` confirmed
  `versionId == activeVersionId` and `.activeVersion.nodes` held the new graph. Yet a **real webhook
  execution 28 minutes later ran the OLD graph** — the tell-tale in `get_execution`: a node's `source`
  pointed at the pre-edit upstream node, and it threw the pre-edit error. Storage was updated; the running
  webhook trigger process was not.
- Cause: publishing a NEW version of a workflow that is *already active* updates the active version in the
  DB but does not always hot-reload the in-memory webhook registration. So the DB says new, the runtime
  serves old — and `get_workflow_details` (which reads the DB) can't reveal it. **Only an execution can.**
- Fix: **`unpublish_workflow` then `publish_workflow`** (deactivate → reactivate). The reactivation
  re-registers the trigger and re-reads the active version, guaranteeing the runtime matches. A bare
  re-publish is not enough.
- Verification lesson (reinforces the render-check rule): confirming `versionId == activeVersionId` is
  necessary but NOT sufficient — it proves the DB, not the runtime. For a webhook/trigger workflow, the
  only real proof is a live execution (`get_execution`, check each node's `source` + output). Structural
  verification passing while the runtime is stale is exactly how a "verified" deploy still drops leads.
- Found: 2026-07-11 — a webinar registration pipeline.

### Alert on a swallowed append failure without halting the lead: `continueErrorOutput` → Stop And Error → shared errorWorkflow
- Problem: the hardened Sheets-append pattern uses `onError: continueRegularOutput` (a log failure must not
  halt the lead's CRM work). But that also **swallows a genuine append failure** — the run reports success
  and the lead silently never reaches the sheet (see the defineBelow-drift amplifier above). A shared
  `errorWorkflow` (Error Trigger → Slack) never fires because nothing throws.
- Fix that surfaces it loudly without a per-workflow Slack credential: set the append node
  `onError: continueErrorOutput` (its 2nd output now carries only rows that failed *after* the retries),
  and wire that error output to a **`n8n-nodes-base.stopAndError`** node whose `errorMessage` names the tab
  + the lead email. The throw fans into the workflow's `settings.errorWorkflow` (here the global
  "Ops — Workflow Failure Alert" → Slack `#ops`, channelId `C0XXXXXXXXX`), which already prints
  workflow name + error + failing node + run link. Reuses one Slack handler for every funnel.
- Trade-off (accepted, state it): on a genuine append failure the item does NOT continue to the append's
  downstream nodes (it went out the error output). For a terminal/bookkeeping append that's costless; where
  the append gates product delivery (e.g. VSL's video email sits downstream of its log), a sheet outage
  would also pause that email — the deliberate "fail loud" choice for a business-critical sheet. Reorder
  the append onto a parallel branch if you need the product path immune.
- Also: wire `settings.errorWorkflow = <workflow-id>` on every lead funnel — several had none, so even a
  hard crash (e.g. the Contact `consent.trim()` boolean crash) was silent. `setWorkflowSettings` with
  `{ errorWorkflow, executionOrder }` merges cleanly (doesn't wipe the other settings).
- Found: 2026-07-11.

### MCP can't attach credentials to HTTP Request nodes — manual UI step
- Symptom: building via the MCP SDK, HTTP Request nodes are skipped during credential
  auto-assignment, and `setNodeCredential` errors "node type 'n8n-nodes-base.httpRequest'
  does not accept credential 'httpHeaderAuth'" (same for a Sheets OAuth cred via
  `predefinedCredentialType`).
- Cause: HTTP nodes can call any URL, so n8n treats credential binding on them as a manual
  safety step — not bindable by automation.
- Fix: build everything else, then have the user open the workflow and pick the credential
  on each HTTP node in the UI (appears in the dropdown by name). Native integration nodes
  (Google Sheets node, Gmail, etc.) auto-assign fine.
- Also: publishing/activating a workflow is gated by the auto-mode classifier as a
  production deploy — needs the user to explicitly name the workflow to authorize; a generic
  "go ahead" is not enough.
- Found: 2026-06-15 — a landing-page capture pipeline.

### Slack node (v2.5) `messageType: 'block'` + a top-level `text` posts TEXT ONLY (blocks dropped)
- Symptom: built a Slack message with `messageType: 'block'`, `blocksUi: {{ JSON.stringify($json.blocks) }}`,
  AND a top-level `text` (as "fallback"). `ok:true`, but the message that landed contained only the
  `text` — Slack's response `message.blocks` was a single `rich_text` block auto-generated from `text`,
  i.e. the Block Kit blocks never posted.
- Cause: setting the top-level `text` alongside block mode makes the node post the text and drop the
  blocks. (Tell-tale in the chat.postMessage response: `blocks: [{type:'rich_text', ... your fallback}]`
  instead of your section/context blocks.)
- Fix (used by the internal digests): use **`messageType: 'text'`** and put the WHOLE post in one mrkdwn
  string. Slack reliably renders ```code fences``` as an aligned **preformatted** block, `*bold*`, and
  `<url|label>` links — which is all these data posts need, and it sidesteps blocksUi entirely. If you
  truly need Block Kit, set `messageType: 'block'` and do NOT also set `text`.
- Bonus: the attachment **`color`** stripe ("color of the line left of text") only exists on
  `messageType: 'attachment'`, whose body is a mrkdwn `text` field (no Block Kit). Block/text messages
  have no color bar. So "color stripe" and "rich Block Kit" are mutually exclusive on this node.
- Found: 2026-07-10 — an internal Slack ops digest.

### Slack: to post as a BOT (not the authorizing person) + post by channel ID
- Symptom 1 (identity): the built-in `Slack account` credential (slackOAuth2Api) posts as **you** (it's
  a user OAuth token). To post as a bot, create a Slack app with a bot user + `chat:write`, install it,
  and use the **Bot User OAuth Token** (`xoxb-`) in a **`slackApi`** credential; set the node
  `authentication: 'accessToken'`. Then it posts under the bot's name/icon.
- Symptom 2 (`channel_not_found`): a bot with only `chat:write` cannot resolve a channel by **name**
  (n8n calls conversations.list, which needs `channels:read`). Post by **channel ID** instead — set
  `channelId` RLC `mode:'id'`. Get the ID from any prior post's response (`.channel`) or the channel's
  "Copy link". (Or grant `channels:read`+`groups:read` and reinstall to allow name mode.)
- Symptom 3 (`invalid_arguments`): the channel value resolved to empty — a downstream Code node dropped
  the field. Reference the source node directly, e.g. `{{ $('Set Config').item.json.channelId }}`,
  rather than `$json.channelId` which only exists if the immediate previous node passed it through.
- The bot must be **invited to the channel** (`/invite @botname`) before it can post there.
- Found: 2026-07-10 — an internal Slack ops digest.

### `Funnel` spine column is unreliable — group multi-tab reads by SOURCE TAB, not a data column
- Symptom: a digest that read all `*-leads` tabs, merged them, and grouped rows by the `Funnel` column
  counted ~0 — many rows have `Funnel: ""` (the funnel pipelines don't all populate it).
- Fix: don't trust the column. Read each tab into its own node, then in a Code node pull each by name
  (`$('Read webinar-leads').all()`) and tag the funnel from the tab you read it from. Keep a `Merge`
  upstream purely as the sync barrier so every read has finished before the Code node runs.
- Found: 2026-07-10 — a multi-source Slack digest.

### SDK code parser: no top-level function declarations or loops in the composed workflow
- Symptom: `validate_workflow` → "FunctionDeclaration: Function declarations are not allowed in SDK code".
- Cause: the SDK parser only accepts `const` node definitions + a single fluent `workflow()...` chain.
  A `function makeRead(){...}` helper or a `.forEach`/reassigned-`wf` loop to fan out N nodes fails to parse.
- Fix: write each node as an explicit `const` (r0..r8) and one chained `export default workflow()...` with
  `.add(setConfig).to(rN.to(mrg.input(N)))` per branch. (Helpers/loops are fine INSIDE a Code node's
  `jsCode` string — that is runtime JS, not SDK code.)
- Found: 2026-07-10 — a multi-source Slack digest.

### Code node `runOnceForEachItem` MUST return a single `{ json: {...} }` — an array throws + sends ZERO
- Symptom: a webhook send workflow errors immediately with **"A 'json' property isn't an object [item 0]"**
  on the Build Email / build-payload Code node; the run stops on the FIRST item, so **nothing downstream
  fires** (no Resend call, no log, no row marked Sent).
- Cause: the Code node is in **`mode: runOnceForEachItem`**, whose contract is **return ONE item object**:
  `return { json: {…} };`. Returning an array (`return [{ json: {…} }];`) — the shape `runOnceForAllItems`
  wants — makes n8n read `[0]` as the `json` value, which is an array, not an object → throws. The two
  modes have opposite return contracts; copy-pasting a body between them silently breaks this.
- Fix: `runOnceForEachItem` → `return { json: {…} };` (single object). `runOnceForAllItems` →
  `return [{ json: {…} }];` (array). Match the return to the mode.
- Why it's nasty: in a throttled 1-at-a-time loop (splitInBatches size 1) it dies on recipient #1, so the
  batch never advances and **0 of N** go out — but the failure looks like a generic type error, not "wrong
  return shape." Verify the fix by a real execution + counting outputs that carry the success key (a Resend
  `id`), never by the node run-count (continue-on-error inflates it).
- Found: 2026-07-13 — a no-show re-engagement sequence.

### Targeted `updateNodeParameters` does NOT strip HTTP creds — only full SDK re-create does
- The credential-stripping hazard is specifically **`create_workflow_from_code`** (full SDK re-create) — it
  drops the workflow's HTTP-node credential bindings. A **targeted `update_workflow` → `updateNodeParameters`** op
  (Set/Code node params, or even an HTTP node's own `jsonBody`/text param) writes only into `parameters` and leaves
  `node.credentials` untouched → creds survive. So the old "edit these nodes only in the UI to protect creds" rule
  is narrower than thought: Code/Set/param edits can be done programmatically.
- Still required: use `updateNodeParameters`, NOT `setNodeParameter` (silently no-ops on large `jsCode`); preserve
  `\'` apostrophe escapes and literal `<`/`>` (don't HTML-entity-escape the code); and **verify by execution**. For
  a **webhook-triggered** workflow, still do the publish → deactivate→reactivate flush (see the "already-ACTIVE
  webhook serves the OLD graph" gotcha above) — DB `versionId==activeVersionId` proves the DB, the live exec proves
  the runtime.
- Found: 2026-07-14 — `Webinar — Post-Sync`.

### `errorWorkflow` does NOT fire for MANUAL executions — a manual-trigger workflow alerts nowhere
- Setting `settings.errorWorkflow` on a workflow whose only trigger is `manualTrigger` looks like
  coverage and is not. n8n's own docs are explicit: **failure handling fires for production executions
  only, not manual/test runs.** So the alarm is armed for a path that workflow never takes.
- Why it matters more than it sounds: the workflows people run by hand are often the **bulk** ones — a
  post-webinar sync that tags an entire cohort in the CRM, sends everyone an email and rewrites sheet
  rows. That is the worst place for a silent half-completion.
- **The mitigation for a manual workflow is the operator, not the config.** Watch the run to completion
  in the UI rather than firing and walking away, and prefer designs that fail *early and loudly*
  (a guard that throws at the top) over ones that fail halfway through a cohort.
- Set `errorWorkflow` anyway — it costs nothing, and it starts working the moment the workflow gains a
  schedule, webhook, or is called as a sub-workflow. Just **do not count it as coverage while the only
  trigger is manual.**
- Found: 2026-09-04 — `Webinar — Post-Sync`.

### Crypto node HMAC: use typeVersion **1** for a `$vars`/expression secret — v2 needs a bound credential
- Symptom: a Crypto node set to HMAC-SHA256 with `secret: {{ $vars.UNSUB_SECRET }}` throws
  **`NodeOperationError: Node does not have any credentials set`** and the inline `secret` you passed is
  silently ignored.
- Cause: **Crypto node v2** moved the HMAC secret to a bound **`crypto` credential** (`CryptoV2Credentials { crypto }`);
  it does NOT read an inline `secret` param. **Crypto v1** keeps an inline `secret` string/expression field that
  accepts `={{ $vars.X }}` directly.
- Fix: for a secret that lives in an n8n **Variable** (or any expression), use **`typeVersion: 1`**. Only use v2 if
  you're willing to create a `crypto` credential holding the key. v1 params: `action: 'hmac'`, `type: 'SHA256'`,
  `value`, `secret`, `encoding: 'base64'|'hex'`, `dataPropertyName`.
- Related: n8n Cloud Code nodes **block `require('crypto')`** (can't set `NODE_FUNCTION_ALLOW_BUILTIN` on Cloud), so
  the Crypto node is the way to HMAC. But `Buffer` IS a Node global (not a blocked require) → base64/base64url
  transforms work fine inside a Code node (`Buffer.from(s).toString('base64')` then `.replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'')`).
- Found: 2026-07-15 — an unsubscribe/suppression audit.

### Idempotency keys must never include a client timestamp
- Symptom: a form guarded by an idempotency check still produced duplicate rows on every resubmission.
  The guard looked correct and was provably correct in isolation.
- Cause: the key was `sha256(email + '|' + submitted_at)` and `submitted_at` was generated in the
  **browser** (`new Date().toISOString()`) on every submit click. Every retry therefore hashed to a new
  key, `is_duplicate` was always false, and the whole pipeline re-ran. **A timestamp is the one field
  guaranteed to differ between a request and its retry — which is exactly the case the key exists to
  catch.**
- Fix: key on *what makes the request the same* — identity + event (`email + webinar_date_iso`), never
  *when it was sent*. A different event still yields a different key, so genuine repeats pass through.
- **Companion trap:** if the store also records failures (`Mark Processed - Failure`), a now-stable key
  makes a partially-failed run block that contact **forever**. Only treat `status === 'success'` as a
  duplicate. The volatile key was masking this — fixing one bug would have created a worse one.
- Diagnose with `search_executions`: N executions all `success` = the client sent N requests (retry);
  1 execution = a workflow loop. Different root causes, different fixes.
- Found: 2026-07-28 — a webinar registration pipeline.

### Analytics in a success path can turn conversions into apparent failures
- Symptom: a registrant submitted 3× in 21s. The webhook had returned **200 in 1.46s** each time.
- Cause: `fbq('track','Lead')` and `dataLayer.push()` sat **unguarded inside the same `try` as the
  fetch**. In a privacy-restricted in-app WebView (`x-requested-with: com.particlenews.newsbreak`,
  Android WebView, arriving from a Facebook ad) `fbq` throws → execution falls to the `catch` → shows
  "Network error… try again" → re-enables the button. The user had already registered successfully.
- Blast radius: this only hits **in-app browsers on paid social traffic** — the exact population being
  paid for. Silent when the user doesn't retry; they just believe registration failed.
- Fix: wrap every analytics call in its own `try/catch`. Never let telemetry sit where a throw can reach
  a user-visible error path.
- Found: 2026-07-28 — a webinar registration pipeline.

### `$('Read Config').first()` means ROW 1, not "the relevant row" — a 2nd sheet row breaks it silently
- Symptom: a workflow reads a config tab and behaves as if configured for the **wrong event** — or, worse,
  a gated workflow no-ops every run and reports success. Three sites in one campaign had this: WF-N2
  `Select Recipients` + `Finalize` (config values and the `Set Status Sent` matching key came from the
  oldest webinar) and WF-N1 `Gate` (`status === 'pending'` was never true → the day-before nudge would never
  have fired; it had been dead 16 days).
- Cause: `.first()` is a **positional** accessor. On a Sheets read it is literally row 1 of the tab. It
  works perfectly while the config tab holds ONE row, and breaks the moment a second is added.
- **Why git can't find it: the trigger is a DATA change, not a code change.** No commit, no deploy, no
  diff. Code that reads external state can be broken by a change to that state.
- Two reasons it hides:
  - **A bad write can be self-concealing.** `Set Status Sent` re-stamped `status: sent` on a row that
    already said `sent`. A wrong write that lands on an already-correct value leaves no evidence.
  - **A silent no-op is indistinguishable from a correct one.** `return []` on a closed gate is the right
    behaviour; nothing tells you the gate closed for the wrong reason. An error would have paged you.
- Fix: select by the field that **means** something. `rows.find(r => r.send_date === todayPT)` for a
  date-triggered stage; nearest `webinar_date >= today` for "the upcoming event". Never `.first()` on a
  tab that can grow. (The SDK reference says the same: use `.first()` only for a genuinely single global
  config row.)
- Companion trap — **one `status` field, two campaigns.** The invite send and the day-before nudge shared
  a config row; the invite stamps `sent`, which re-breaks the nudge's `status === 'pending'` gate even
  after fixing `.first()`. Fix: gate on `send_date === today` alone (already once-per-day, and a
  `Clear Staging` step makes a repeat run idempotent), so `status` stops being load-bearing.
- Found: 2026-07-30 — a campaign roster builder.

### MCP `addConnection` IGNORES `sourceOutput` — every branch silently lands on output 0
- Symptom: added a Switch with three branches via `addConnection` + `sourceOutput: 0/1/2`. The call returned
  `appliedOperations: 17`, **zero validation warnings**. The live graph had:
  `"Route Event": { "main": [[ {Is Valid?}, {Respond 200 Canceled}, {Respond 200 Dropped} ]] }` — **one**
  output array holding all three targets. Outputs 1 and 2 were never created.
- Blast radius: on a Switch, output 0 is the FIRST match, so every `invitee.created` booking would have
  fired the **cancel branch too** — marking itself Canceled, writing a spurious "booking CANCELED" CRM
  note, and hitting two credential-less HTTP nodes. Multiple `respondToWebhook` nodes on one path as well.
- Tell-tale in an execution: the Switch shows correct routing (`main: [[], [item], []]`) but
  `lastNodeExecuted` is the Switch itself — it classified fine, and nothing downstream ran because the
  real items sat on an output with no connection.
- **`setNodeSettings` DOES work** (proven: `executeOnce` on a Sheets read). But **node-level `onError` /
  `retryOnFail` / `alwaysOutputData` passed inside an `addNode` payload are silently dropped** — set them
  in a separate `setNodeSettings` op after the node exists.
- Fix: don't wire multi-output nodes (Switch / IF) via MCP. Add the nodes unconnected, leave the existing
  working path untouched, and have the operator drag the branch connections in the UI — which they must
  visit anyway to bind HTTP credentials. Rebuilding via `create_workflow_from_code` is NOT an alternative
  on a credential-bound workflow (it strips HTTP creds).
- **Process rule this violated: for a STRUCTURAL change, read the connections back BEFORE publishing.**
  `get_workflow_version` returns the full connection map. Parameter edits can be verified after publish;
  rewiring cannot, because the failure mode is a live workflow doing the wrong thing. Recovery here was
  `restore_workflow_version` to the last good version → publish → deactivate→reactivate → re-probe.
- This is the SAME family as the `setNodeParameter` no-op above: **`appliedOperations` counts operations
  attempted, not effects realized.** Two distinct fields on one call were accepted and discarded.
- Found: 2026-07-31 — a booking-capture pipeline.

### A chained second READ runs ONCE PER UPSTREAM ITEM — a 2-row config tab silently doubles the send list
- Symptom: a send workflow queued roughly twice as many recipients as the staging tab held. `Read Staging` had
  returned exactly 2× the rows. Every approved contact appeared twice, so a completed run would have
  double-sent the same invitation to every approved contact. The sheet itself was clean; the *read* was doubled.
- Cause: `Read Staging` is chained after `Read Config`. The config tab had grown to **2 rows**, so
  `Read Config` emitted 2 items, and n8n runs a chained node **once per input item**. Two runs of the read
  → `$('Read Staging').all()` returns both runs' output concatenated.
- Fix: **`executeOnce: true`** on the second read (MCP op is `setNodeSettings`, NOT `updateNodeSettings`).
  It then runs once regardless of upstream item count. Alternative: put the two reads on parallel branches
  into a Merge. The SDK reference documents this under `<independent_sources>` — it is invisible until the
  upstream count changes from 1.
- **Same trigger as the `.first()` family above: a second row in the config tab.** One data change broke
  four things at once — three `.first()` selectors picked the wrong row, and this read started running
  twice. All four worked fine while that tab held exactly one row. **When a config tab goes from 1 row to 2,
  audit every node that reads it AND every node chained after it.**
- Diagnose by comparing node run-count and row-count against the real tab: `runData['<Read>'] | length`
  should be 1, and rows returned should equal the sheet. A fresh CSV export is ground truth; the
  execution's read is not.
- Near-miss worth remembering: this only avoided going out because an *unrelated* `Check Suppression`
  sub-workflow timeout (60s task limit) killed the run partway through the first pass. Luck, not
  design, was the last line of defence. What made recovery clean was the resumable gate
  (`Approved && !Sent`): a re-run reaches only the unsent, never re-sends.
- Found: 2026-07-31 — a no-show re-engagement sequence.

### Sheets `appendOrUpdate` CREATES on a miss — use `update` when "no match" should mean "do nothing"
- Symptom: a render check using a synthetic recipient was verified as "touched zero staging rows", then the
  synthetic address turned up **as a new row in the tab**.
- Cause: the write-back node was `operation: appendOrUpdate` matching on `Email`. With no matching row it
  does not no-op — it **appends**. `operation: update` is the one that no-ops (and, per the older gotcha
  above, outputs `[]`, so set Always Output Data if a downstream node must still run).
- Companion trap: with duplicate rows in the tab, `update` stamps only the **first** match, leaving the twin
  unstamped and therefore still eligible on the next run.
- **Verification lesson: a CSV export is only evidence if it was taken AFTER the event you are checking for.**
  The "zero rows touched" claim was checked against an export saved 18 minutes *before* the render check ran.
  Verified-against-stale is worse than unverified — it manufactures confidence. Check the file's mtime.
- Found: 2026-07-31.

### `TEST_MODE` usually guards only the RECIPIENT — every write downstream still runs for real
- Symptom (caught before firing): WF-N2's `Build Email` has `to = TEST_MODE ? [TEST_INBOX] : [n.email]`.
  With a full approved staging tab, a "safe render check" would have sent **one email per approved row to the test inbox**
  AND run `Mark Row Sent` + `Log Send` + `Set Status Sent` for real — stamping every row `Sent`, after
  which the real send finds **zero eligible recipients** and quietly does nothing. The test consumes the
  campaign.
- Cause: the test flag sits at the last node that touches the address, but the loop, the sheet write-backs
  and the config stamp are all downstream of it and unaware.
- Fix: guard **who** as well as **where**. Add a `RENDER_CHECK` flag in the recipient-selection node that
  short-circuits to ONE **synthetic** recipient that exists in no staging row — then the `update`-mode
  Sheets node matches nothing and the roster is untouched. Two independent flags; flip both to go live.
- Verify by asserting the *absence* of side effects, not just a successful send: grep the staging export
  for the test address (must be 0) and confirm the approved rows are still unsent.
- Generalizable: any "test mode" that only rewrites a destination is a **partial** guard. Ask what else
  the run writes.
- Found: 2026-07-30 — a no-show re-engagement sequence.

### Roster/exclusion filters: stage exclusions VISIBLY, never drop them silently
- Symptom: asked to exclude a list of named contacts from a larger send. Staging them with `Approved = FALSE`
  + a reason (instead of filtering them out) plus reporting any name that matched nothing immediately
  caught that the CRM spells it **Thornbury**, not `Thornbery` as supplied — one character. That
  contact was staged **Approved** and would have been sent.
- Why silent filtering is worse than none: the roster would have been a roster that *looked* correct —
  every requested name gone from view, no signal anywhere. Absence is not observable.
- Fix pattern: (a) keep excluded rows in the output with an explicit reason, (b) count them, (c) report
  every requested exclusion that produced **no match**, (d) match tolerantly (last name exact + first-name
  prefix either direction, so `Ben` matches a stored `Benjamin`).
- **Rule: when a filter can fail, make its failures countable.**
- Found: 2026-07-30 — a campaign roster builder.

### Wealthbox `status`/`contact_type` are NOT usable discriminators — and `updated_at` measures YOUR writes
- Measured across the full contact base: `status` is `Active` for **every single one** (Wealthbox default) and
  `contact_type` is blank for **every single one**. Neither can carry an "active client" / exclusion flag —
  that has to be a tag, or a per-campaign review column.
- `updated_at` buckets came back `<30d: ~74% · 30–90d: ~26% · 90–365d: 0 · >365d: 0`. **Not one contact has
  gone 90 days without an update — because the pipelines themselves rewrite them** (every drip enrollment, tag
  change and note write bumps it). Used as a staleness/engagement proxy it classifies the entire CRM as
  freshly-engaged. Infer engagement from **tags** (`webinar:*`, `src:calendly`, `meeting-held`), never from
  the activity timestamp.
- Contact list endpoint: `GET /v1/contacts?per_page=100&page=N` → `{ contacts: [...], meta: { page,
  total_pages, total_count } }`. n8n HTTP pagination:
  `paginationMode: 'updateAParameterInEachRequest'`, qs `page` = `{{ $pageCount + 1 }}`,
  complete when `{{ $response.body.meta.page >= $response.body.meta.total_pages }}`.
- Found: 2026-07-30 — a CRM contact-universe probe.

### A workflow left failing into the shared `errorWorkflow` DEGRADES EVERY OTHER ALARM
- Symptom: a real, correct, well-built alert (the Form Pipeline lead-drop tripwire) fired into
  `#ops` and went unread long enough to matter — a captured lead sat un-backfilled. Nothing was wrong
  with the alert.
- Cause: `Outreach — Content Intake (WF-A)`, a Drive trigger polling every minute, had
  been failing on every run since at least 2026-08-20 on
  `Quota exceeded … drive.googleapis.com`. It names the shared `errorWorkflow` <workflow-id>, so
  every failure posted to `#ops` — **dozens of alerts a day for two weeks.** Confirmed by pairing timestamps, not
  assumed: the WF-A failure at `15:00:48.284Z` → the alert at `15:00:48.720Z`.
- **The alerting channel is a SHARED RESOURCE.** Any workflow allowed to fail repeatedly into it burns
  down the signal value of every other alarm wired to the same handler. Noise is not cosmetic — here it delayed response to a true alert by more than a day, and hid a second unrelated failure entirely.
- Fix: disable or mute a workflow that has failed N times consecutively — don't leave it shouting. A
  workflow that has processed nothing in two weeks loses nothing by being deactivated.
- Diagnose the whole instance, not one workflow: `GET /api/v1/executions?status=error&limit=40` and
  group by `workflowId`. One ID dominating the list *is* the finding.
- Found: 2026-09-03 — an estate-wide audit.

### `get_sdk_reference` down ≠ SDK build blocked — read the MCP **resource** instead
- When `get_sdk_reference` returns `MCP error -32602: Tool not found` (it has been down since at least
  2026-08-27), the identical reference is still served as an MCP **resource**:
  `ReadMcpResourceTool(server="claude.ai n8n", uri="n8n://workflow-sdk/reference")` (~50 KB).
- This unblocks `validate_workflow` + `create_workflow_from_code`. The previously-planned workaround
  (have a human create an empty workflow shell in the UI, then build it up with `addNode` ops) is
  **not needed**. Confirmed 2026-09-03 by building `Webinar — Lead Reconcile` this way end-to-end.
- Check `ListMcpResourcesTool` first whenever an MCP *tool* is missing — the capability may still exist
  on the resource side.

### REST `PUT /workflows/{id}` writes the ACTIVE version directly — MCP `update_workflow` writes a DRAFT
- Two write paths with **different semantics**, easy to conflate:
  - **MCP `update_workflow`** → writes a **draft**. `versionId != activeVersionId` until you
    `publish_workflow`. An active workflow keeps running the old graph meanwhile.
  - **REST `PUT /api/v1/workflows/{id}`** → updates the workflow **in place**; on an active workflow
    `versionId == activeVersionId` immediately afterwards, **no publish step and no draft divergence**.
    Found: 2026-09-03 — a landing-page capture pipeline.
- **Why this matters:** the REST path is the better tool for a *bulk, mechanical* edit across many
  nodes (it is scriptable, so there is no hand-transcription risk on large `jsCode` bodies), and it
  skips the publish dance. But it also means **there is no draft to review** — the change is live the
  moment it lands. Use MCP when you want a draft; use PUT when you want it applied.
- **PUT recipe that preserves everything:** GET the workflow → mutate only the node fields you want →
  PUT `{name, nodes, connections, settings}`. **Strip every other top-level key** and filter `settings`
  to the allowed set (`executionOrder`, `timezone`, `errorWorkflow`, `save*`, `callerPolicy`,
  `callerIds`, `executionTimeout`) or you get `400 must NOT have additional properties`.
- **Verify by diffing the node map before/after**, not by the response: confirm only the intended nodes
  differ, node count is unchanged, `connections` are byte-identical, `credentials` survive on every
  node, and `active` is untouched. Proven safe across 16 nodes / 7 workflows this way.
- **Syntax-check `jsCode` before writing it** — `node --check` on the new body. A string substitution
  inside a template literal is exactly the kind of edit that silently breaks JS, and on a live capture
  workflow that costs leads.
- Found: 2026-09-03 — a regulated-industry copy audit.

### Credentials DO bind through node-creation payloads — the "skipped" warning lies
- The earlier gotcha ("MCP can't attach credentials to HTTP Request nodes") is narrower than written:
  it is true of the **`setNodeCredential` op**, not of node creation.
- Passing `credentials: { httpHeaderAuth: { id: '<credential-id>', name: 'Livestorm API' } }` inside
  either an `addNode` payload **or** `create_workflow_from_code` binds correctly — including on
  `n8n-nodes-base.httpRequest`. Both still emit
  `"HTTP Request nodes (…) were skipped during credential auto-assignment"`. **That warning is not
  reliable — read the nodes back and check `node.credentials` before believing it.**
- In SDK code use an explicit `{ id, name }`, **not** `newCredential('Name')` — `newCredential` creates a
  *new empty* credential (validation warns `PLAIN_GENERIC_AUTH`), which silently duplicates the real one.
- Found: 2026-09-03 — a webinar registration pipeline.

### Sweep EVERY Code node with `node --check` — and write to an archived workflow via unarchive → PUT → archive
- **The sweep.** One bad `jsCode` body is never evidence about the rest. Pull every workflow
  (`GET /workflows?limit=250&includeArchived=true`), write each node's `jsCode` to a file, run
  `node --check`, and group the failures by archived / live / paused. a few hundred nodes takes seconds and is the
  only way to answer "is anything else broken?" — which is the question that actually matters after
  finding one. Run it whenever a syntax bug turns up: **when you fix one, grep for the others the same day.**
- **Known false positive: top-level `await`.** n8n wraps a Code node body in an async function, so
  top-level `await` is valid there and `node --check` (which parses a bare script) rejects it. Before
  reporting such a hit, re-check it wrapped: `printf 'async function f(){\n' > w.js; cat body.js >> w.js;
  printf '\n}\n' >> w.js; node --check w.js`. If it passes wrapped, the code is fine.
- **Archived workflows reject writes** — `PUT` returns `400 Cannot update an archived workflow`. There are
  undocumented endpoints: **`POST /workflows/{id}/unarchive`** and **`POST /workflows/{id}/archive`** (both
  200). So the write path is unarchive → PUT → archive, and **put the re-archive in a `finally`** so an
  error mid-way cannot leave a retired workflow un-retired. Unarchiving does NOT activate anything;
  `active` stays as it was. Verify `isArchived` is back to `true` afterwards.
- **Fixing the bare-apostrophe bug mechanically.** Scan the source tracking quote state; inside a
  single-quoted string a `'` whose next char is a **letter** is an embedded apostrophe (`I&#39;ve`,
  `a contact&#39;s`) → replace with `&#39;`; a `'` followed by whitespace/`+`/`,`/`;`/`)` is a real terminator.
  That heuristic fixed 51 apostrophes across 7 nodes with zero misfires. `&#39;` renders as `'` in HTML
  email, so output is unchanged. Always `node --check` each body after.
- Found: 2026-09-09 — a cold-outreach drip pipeline.

### Refactoring approved email copy: prove it by RENDERING old vs new, not by reading the diff
- Situation: an email body carries hard-coded event values (dates, times) that a config row already
  supplies. The fix is to derive them — but the body is **approved copy**, so the bar is
  proving the *rendered output* is unchanged, not that the edit looks right.
- Method that actually proves it: pull both the old and new `jsCode`, run each with `new Function('$', code)($stub)`
  supplying a stubbed `$('Node')` for every node the code references, and **diff the resulting HTML string**.
  Byte-identical output against the ORIGINAL config values = the approved wording is untouched. Reading the
  diff cannot show this; a template refactor changes every line that gained a `${}`.
- **Then render the NEW case too — that is where the bug will be.** A regression test against the old date
  passes trivially. Deriving a time *range* from "2–3 PM" looked correct until the new event was 11 AM–12 PM
  and the same code emitted "11–12 PM": dropping the start meridiem is only valid when both ends share it.
- Derive PDT/PST by **reading** it — `Intl.DateTimeFormat(…, {timeZone:'America/Los_Angeles', timeZoneName:'short'})`
  `.formatToParts()` → `PDT`/`PST` — then offset 7 or 8. Never hard-code the offset; a Nov–Mar webinar breaks it.
- Make the fallback non-throwing (return the config text verbatim on an unparseable date). A throw inside a
  per-item Build Email node in a `splitInBatches` loop kills the whole send, not one item.
- **The generalizable smell: the plumbing exists and is unused.** `Select Recipients` had been putting
  `webinarDate`/`webinarWhen` on every item and `Build Email` ignored both — so the config tab looked like it
  controlled the email and did not. When a value is hard-coded, check whether it is *already being passed in*
  before adding a new field.
- Found: 2026-09-09 — a no-show re-engagement sequence.

### Capture-only restore: disable the SEND node, don't deactivate the workflow
- Problem shape: a compliance/vendor hold forces you to stop *sending*, so the whole workflow gets
  deactivated — and the **front end keeps inviting submissions**. Deactivating a webhook workflow makes
  the endpoint return **404**, so the lead never reaches n8n at all: no CRM contact, no sheet row, no
  Slack ping, and no `Respond OK`, which also kills the browser-side Meta `Lead` pixel (it fires on a
  200). **The lead is not queued anywhere — there is nothing to process later.** Any "we'll handle those
  by hand until this clears" plan is dead on arrival, because nothing tells you one arrived.
- Fix: keep the workflow **active** and disable only the send node. **A disabled n8n node passes its
  input straight through to its outputs**, so every downstream node still runs — including a Slack notify
  wired *after* the sender, the CRM forward, and `Respond OK`. You get full capture, live attribution and
  an arrival signal, with zero automated mail.
- Prove it by execution, and check the send node's **output shape**: a disabled HTTP node echoes its
  *input* (here the `{to, subject, html}` payload). A node that really called Resend returns
  `{id: "<uuid>"}`. Same-looking `executionStatus: success`, completely different meaning.
- Also assert it is the *only* sender before claiming "no email can leave":
  `jq '[.nodes[] | select((.parameters.url // "") | test("resend|mail";"i")) | .name]'`.
- **The honest-copy corollary:** this restores capture but the page may still promise an emailed
  result. Either change the copy, or commit to a human keeping the promise — the rendered HTML is sitting
  in the execution's build-email node output, ready to paste and send from an archived mailbox.
- **Probe a webhook safely with the honeypot filled** (`<honeypot_field>: "<excluded-prefix>…"`) — it routes to the
  drop branch and returns 200 without minting a lead, a contact or a CAPI event.
- Found: 2026-08-26 — a landing-page capture pipeline.

### A skipped node inside a `splitInBatches` body STALLS THE LOOP — and an ordered queue turns that into a poison pill
- A node that receives **zero items is skipped entirely** (it does not run). If that node is inside
  the loop body, everything after it is skipped too — including `nextBatch`. The loop never advances
  and the execution just ends, **status `success`**, with the remaining batches untouched.
- **The amplifier: if the queue is ordered, the bad row is first EVERY run.** `Find Sessions Due`
  ordered `last_seen ASC` with `batchSize 1`, so one session whose child read returned nothing sat at
  the head of the queue forever and blocked every session behind it. One orphan row = all processing
  silently stopped, and only a separate monitor would ever notice.
- Fix: `alwaysOutputData: true` on the node that can legitimately return nothing, then handle the
  empty case explicitly and still reach `nextBatch`. This is the **narrow, correct** use of
  `alwaysOutputData` — the SDK reference rightly warns against it as a default, but "a skipped node
  would strand a loop" is exactly the exception it names.
- ⚠️ **`if (!items.length)` INSIDE that Code node is unreachable dead code** — the node never runs
  when there are zero items, so the guard can never fire. Worse than useless: *it reads as coverage*
  and stops you looking. If you have written such a guard, check whether the node can even execute.
- Found: 2026-09-15 — a chatbot session archive.

### `neverError: true` makes `retryOnFail` DEAD CODE — and hands the failure downstream as success
- Setting `options.response.response.neverError` on an HTTP node means a 4xx/5xx **is not an error**.
  Two consequences people miss:
  1. **`retryOnFail` never fires.** Any retry you configured for rate limits is decoration. The
     Resend 10-req/s mitigation in `resend.md` was silently inert on a node built this way.
  2. **The item flows on down the success path**, carrying the error body. Whatever is downstream —
     a "mark as sent" stamp, a log row, an idempotency flag — records the work as done.
- The combination is the silent-loss shape this repo keeps rediscovering: on `Session
  Archive` a failed send would have been stamped `archived: true`, never retried (nothing re-selects
  an archived row), and **invisible to its own reconcile monitor**, which filters on that same flag.
  A compliance record lost behind a stamp claiming it was filed.
- Use `neverError` only when you genuinely want to inspect a non-2xx and branch on it, and then
  **branch on `statusCode` explicitly**. If the right answer is "retry, then fail loud", leave it off
  so the retries run and a persistent failure throws into the `errorWorkflow`.
- Found: 2026-09-15.

### Data Table `upsert` with `defineBelow` MERGES — it does not null the columns you left out
- Verified by probe: a row holding `archived: true`, `archive_message_id` and `event_count`
  kept all three after an upsert that listed only `session_id` + `last_seen`.
- Found: 2026-09-15.
- That merge behaviour is what makes a two-writer design safe: a per-event intake can touch `last_seen` on a session
  row the archiver has already stamped, without clearing the stamp and causing a duplicate send.
- Do not assume the opposite either — **probe it** when a second writer touches a row that carries a
  "done" flag, because the failure mode is a duplicate outbound message.

### `Intl.DateTimeFormat().format()` THROWS on an Invalid Date — `toLocaleString()` does not
- `new Intl.DateTimeFormat(...).format(new Date("nonsense"))` raises `RangeError`;
  `new Date("nonsense").toLocaleString(...)` quietly returns `"Invalid Date"`. Mixing the two in one
  Code node means a single bad client timestamp throws where you expected a placeholder — and inside
  a `splitInBatches` body that becomes the loop stall above.
- Guard the date before formatting, or wrap in try/catch and fall back to a literal.

### MCP `execute_workflow` can only send an OBJECT body — a `text/plain` webhook's real path is untestable that way
- A beacon endpoint sends `Content-Type: text/plain` on purpose (it keeps the POST a CORS **simple**
  request, so no preflight). n8n then delivers `$json.body` as a **raw string** the node must `JSON.parse`.
- But MCP `execute_workflow`'s `webhookData.body` is typed as an object, so a manual test **always**
  exercises the object branch and **never** the string branch that production actually uses. A green
  manual run is therefore not evidence the live path works.
- Write the validator to accept both, and test the string path with a real POST against the
  `webhook-test/...` URL while the UI is armed (browser-only — there is still no "run now" API).
- Same family as the "verify by execution" rule: *which* execution matters. Found 2026-09-15
  (`Event Intake` <workflow-id>).

### Data Table: derive counters at read time, never increment them at write time
- A per-event webhook that also keeps a per-session row is tempting to give running counters
  (`event_count`, `interactions`) and increment them on each write. That is a **read-modify-write race**:
  `sendBeacon` fires bursts, two executions interleave, and one silently clobbers the other's count.
  There are no transactions to save you.
- Keep only fields that are safe under concurrency — a `last_seen` timestamp is, because it tracks
  *arrival* order and only moves forward. Derive every count from the event rows when you read them.
- Idempotency: `operation: 'upsert'` with `matchType: 'allConditions'` on (id, seq) makes a beacon retry
  a no-op. Keep **no timestamp in the key** — see the idempotency gotcha above; a timestamp is the one
  field guaranteed to differ between a request and its retry.
- Prefer **one JSON `payload` column** over a column per event field when event shapes differ. A fixed
  column set that must be reconfigured whenever the payload grows is the Sheets `defineBelow`
  header-drift failure wearing a different hat.
- Found: 2026-09-15 — a chatbot session archive.

### An alarm's QUIET path passing is not evidence the alarm works — prove the FIRING path too
- Symptom: a new reconciler ran clean on its first test — a handful of leads checked, no gaps, Slack correctly
  silent, `status: success`. It was **incapable of posting to Slack**. The Slack node omitted
  `resource`, `operation`, `authentication` and `messageType` and sat on `typeVersion 2.3`. The only
  visible sign was a small red warning triangle on the node in the editor; the execution showed
  nothing, because the node never ran.
- Why it is nasty: a monitor built to catch silent failure, itself failing silently. Activated on
  the strength of the quiet run it would have looked healthy indefinitely and only broken the first
  time something real went missing — i.e. exactly when it mattered, and with nobody watching.
- **Fix: copy a working node's parameter shape verbatim, don't write one from the docs.** The proven
  `Alert #ops` in `Webinar — Lead Reconcile` is the reference:
  `typeVersion 2.5`, `{resource:'message', operation:'post', authentication:'oAuth2',
  select:'channel', channelId:{__rl,mode:'list',value:'C0XXXXXXXXX',cachedResultName:'ops'},
  messageType:'text', text:'={{ ... }}', otherOptions:{includeLinkToWorkflow:false, mrkdwn:true}}`.
- **Force the firing path with labelled synthetic data** — here, one row added to the sheet with an
  address that survives the filter, run, confirm the alert names the person, then delete the row.
  Mind your own exclusion regex when choosing the fixture: a natural `zz-`-prefixed test address
  would have been silently skipped and read as a broken alarm.
- Found: 2026-09-17 — a CRM/sheet reconciler.

### Reconcile on IDENTITY, not on a `src:` tag — tags are written only on CREATE
- `src:estimator` / `src:vsl` / `src:webinar` are set in the `Create Wealthbox Contact` body. The
  `Wealthbox Contact Exists?` **true** branch goes straight to `Capture Wealthbox ID`, so a contact
  that already existed **never receives the funnel tag**. Tag-based reconciliation therefore flags
  every repeat visitor as missing from the CRM.
- On a CRM with many repeat contacts that is a permanent false alarm on the shared `#ops` channel — the exact mechanism that lets a true alert go unread.
- Reconcile by `GET /v1/contacts?email=` per lead instead: exact, and immune to the create-vs-update
  asymmetry. n8n runs an HTTP node once per input item natively, so this needs **no `splitInBatches`**
  and cannot hit the skipped-node-stalls-the-loop trap.
- Pair responses back to leads with `$('Node').itemMatching(i)`, not by array index — assuming the
  HTTP node returns items in input order holds until it silently doesn't.
- Found: 2026-09-17.

### Sheets READ omits trailing empty cells — an absent key is not a missing column
- A Google Sheets read returns each row as an object keyed by header, but **stops at the row's last
  non-empty cell**. A blank cell in the LAST column produces **no key at all**, not `""`.
- So `r.hasOwnProperty('Report Sent')` is false for every unsent row. A "column is missing" guard built on
  key presence false-alarmed on the first run and posted a bogus warning to #ops.
- Fix: treat absent == blank, and match headers case-insensitively (a human typed `Report sent`).
  A renamed header then shows every row as unsent, which fails loud rather than silent.
- Found: 2026-09-19 — a site calculator capture flow.

### Branches run DEPTH-FIRST — a "parallel fire-and-forget branch" NEVER RUNS if the branch before it throws
- Two targets on one output are **not** parallel. n8n v1 runs the first target's whole chain to the
  end, then comes back for the second. **If anything in the first chain throws, the second target is
  never reached at all** — no error on it, no trace, it simply did not execute.
- **Positive proof** (a successful run, so this is the ordering itself, not just a casualty):
  Observed on a successful run of `Site — Estimator Report`: `Build Report Email` feeds `Send Report (Resend)` **[0]** and
  `Build Estimator Sheet Row` **[1]**. Run order was `Build Report Email` → **eight nodes** of branch
  [0] (Resend, internal notify, CRM forward, Respond OK, the whole CAPI chain) → *then* branch [1].
  Target [1] sat queued for nine nodes while [0] ran to the end.
- **Negative proof** (what it costs): Calendly `Respond 200 OK` feeds `Search Wealthbox Contact` **[0]**
  and `POST to the internal event spine` **[1]**. Checked **every** retained execution across a three-week window: every one threw at `Enroll in Booking Sequence` deep in branch [0], and
  **`POST to the internal event spine` ran in zero of them.** The internal event spine had silently received nothing for weeks and there is no error on it anywhere, because it never executed.
- A throw discards the whole execution stack, queued siblings included. **An empty return does not** —
  it only declines to queue that node's own children, so a sibling branch still runs. (Reasoned from
  that successful run's stack behaviour above; not independently observed, so worth confirming when a
  `Build CAPI Fields` empty return next occurs.)
- **Consequence: "terminal fire-and-forget branch" is a myth unless that branch is ORDERED FIRST.**
  Isolation comes from *running before the risk*, not from being on a different wire. Hanging a CAPI
  call off a response node protects it only if it is target **[0]**.
- Ordering is the array order in `connections[node].main[0]`, and canvas position is the tiebreaker
  signal — **make both agree** (put the protected branch first in the array AND above on the canvas).
- MCP `addConnection` **appends**, so it always makes the new branch LAST — the broken order. To put a
  branch first: `removeConnection` the existing target, `addConnection` the new one, then
  `addConnection` the original back. Three ops, one atomic `update_workflow`.
- A protected branch must be a **terminal leaf**, because a Code node returning `[]` (e.g. CAPI with no
  `event_id`) skips everything downstream — harmless at a leaf, fatal mid-chain.
- Found: 2026-09-21 — a webinar registration pipeline.

### jq `fromdateiso8601` CANNOT parse n8n timestamps — `?` then silently matches NOTHING
- n8n returns `startedAt` with **fractional seconds**: `2026-09-21T16:30:00.097Z`.
  `fromdateiso8601` rejects that (it wants `%Y-%m-%dT%H:%M:%SZ`) and **throws**. The common
  defensive idiom `(.startedAt // "" | fromdateiso8601? // 0) > $cut` then does the worst
  possible thing: `?` swallows the throw, `// 0` makes every timestamp **0**, `0 > $cut` is
  always false — so the filter drops **every** row and the query reports a clean result forever.
- Both `tools/n8n errors` and `tools/preflight.sh` §3 carried this from the day they were
  written (2026-09-04) until 2026-09-21. **Neither ever reported a single failing workflow**,
  while Calendly, the weekly review and the R&D digest were failing weekly. The check written *because*
  the weekly review failed silently for a month was itself silently dead — and it looked healthy, because
  "no failures" is exactly what a working monitor prints on a good day.
- Fix: **compare ISO strings, don't parse.** `((now - N) | todate) as $cut | select(.startedAt > $cut)`
  — lexicographic ordering on ISO-8601 UTC is exact, total, and has nothing to throw.
- **The generalizable trap: `?` converts a parse error into a wrong answer.** Anywhere a `?` or
  `// default` sits on a value used in a *filter*, failure silently becomes "excluded", not
  "error". Prove such a filter by forcing it to MATCH, never by watching it come back empty.
- Found: 2026-09-21.

### A workflow created via REST is NOT callable from MCP until `settings.availableInMCP = true`
- MCP `execute_workflow` returned "Workflow is not available in MCP". Set it with a REST PUT
  (`settings.availableInMCP: true` is accepted alongside the usual allowed keys). Found 2026-09-19.

## Conventions

- Build workflows as **versioned SDK code** in the repo, not click-built.
- Credentials by name, from n8n's credential store — never inline.

## Gotchas (continued)

### The `neverError` + idempotency-stamp combination is a SILENT ONE-WAY DOOR — found twice in one estate
- Shape: node A POSTs to workflow B's webhook with `options.response.response.neverError: true`. B is
  deactivated, so the call returns **`404 "The requested webhook ... is not registered"`** — and
  `neverError` makes that a **success**. The item flows down the *success* path, where a
  "Mark Processed" node stamps an idempotency key. Result: the record is registered with the vendor,
  written to the CRM, logged to the sheet and **marked fully processed**, while the thing the call was
  for never happened. `executionStatus: success`, no alert, nothing red.
- **The idempotency stamp is what makes it unrecoverable.** Without it the person could re-submit and
  self-heal; with it, a retry is rejected as a duplicate. Two individually-reasonable mechanisms
  combine into a one-way door.
- Found: 2026-09-30 — a webinar registration pipeline.
- **Zero-side-effect liveness probe for any n8n production webhook — use this, it costs nothing:**
  send a **GET** to the production URL and read the message.
  - not registered → `"The requested webhook \"GET <path>\" is not registered."`
  - registered → `"This webhook is not registered for GET requests. Did you mean to make a POST request?"`
  The second message proves the **runtime** registered the path and is rejecting only the *method*. No
  execution starts, nothing is enrolled, nothing is sent. This is the missing runtime check for the
  "`versionId == activeVersionId` proves the DB, not the running graph" gotcha above.
- **Ordering trap when fixing it:** do NOT remove `neverError` while the callee is still deactivated —
  every call would then throw, converting a silent failure into a loud one that also breaks the caller
  and floods the alert channel. **Reactivate the callee first, then remove `neverError`.**

### Hardcoded PT→UTC offsets break the moment DST ends — derive the offset, don't constant it
- a webinar email drip `Calculate Email Schedule` holds
  `TEN_AM_PT_UTC = 17`, `EIGHT_AM_PT_UTC = 15`, and `ptDayStr = d => new Date(d.getTime() - 7*msPerHour)`.
  All three are correct **only during PDT**. Verified correct for an October 2026 event (Email 2 → two days before, 10:00 AM
  PDT, Email 3 → the day before, 8:00 AM PDT, `email3When` = "tomorrow").
- **DST ends 2026-11-01.** Any webinar from November on sends Email 2 and Email 3 **an hour early**, and
  `email3When` can flip "today"/"tomorrow" wrongly near midnight. The node's own comment says
  "Update to 18/16 for PST (Nov–Mar) campaigns" — i.e. it is a documented manual step that nothing
  enforces, which is the same class as a stale doc.
- ✅ **RESOLVED 2026-10-01.** All three PDT-only constructs replaced with a derived offset, copying the
  proven `Webinar No-Show — Send :: Build Email` implementation: read `timeZoneName: 'short'` via
  `Intl.DateTimeFormat`, then offset 7 for PDT / 8 for PST. Two details worth keeping:
  **(a)** the zone is probed at **20:00 UTC (~noon PT)** on the target day, never near the 2am local
  DST transition where the reading is ambiguous; **(b)** `ptDayStr` now formats with
  `Intl.DateTimeFormat('en-CA', { timeZone })` instead of subtracting a fixed 7h — the same idiom
  `Pick Target Webinar` already uses, so the estate is consistent.
- **Proved by rendering old vs new, not by reading the diff** (the render-old-vs-new rule above):
  both near-term cases are **byte-identical** on both send times, while Nov 10 2026 and
  Jan 20 2027 move from 9:00/7:00 AM to the intended 10:00/8:00 AM. That is the whole bug and the whole
  fix in one table — and it shows the live event could not be affected.
- Applied by **scripted REST PUT** rather than hand-transcribing 4 KB of `jsCode` into an MCP call.
  Verified the way a PUT must be: 27 nodes → 27, **only `Calculate Email Schedule` differs**,
  connections byte-identical, 9 credentialed nodes unchanged, `active` untouched, the server's copy
  `node --check`s clean and matches the intended source exactly.
- ⚠️ **Runtime flush deliberately NOT done.** The drip is webhook-triggered with parked executions outstanding, and `resend.md` says drain before an unpublish→publish flush. It costs nothing
  to wait: old and new are identical for October, so a stale runtime graph is harmless until then.
  **Do the deactivate→reactivate after the October cohort drains and before any
  November event.**
- **Estate sweep done the same day, as the rule above requires.** Only this one node was genuinely
  affected. `Ops — Weekly Funnel Snapshot` and `Ops — Daily Briefing (AI)` matched the grep but are
  **false positives** — their `7` is `7 * 86400000` (seven days), not a timezone offset. Worth noting
  that a regex for `7` finds far more arithmetic than it finds bugs.

- The fix already exists in this repo and never propagated here: read the zone name rather than assume
  the offset — `Intl.DateTimeFormat('en-US',{timeZone:'America/Los_Angeles',timeZoneName:'short'})`
  `.formatToParts()` → `PDT`/`PST`, then offset 7 or 8 (learned 2026-09-09 on `Webinar No-Show — Send`).
  **When a timezone fix is made, grep the estate for the other copies the same day.**

### `onError: continueRegularOutput` is the OTHER half of the silent-swallow family — grep for both
- The `neverError` gotcha above is written around `neverError: true`. **`onError: continueRegularOutput` does the
  same damage by a different switch:** the failed item continues down the *success* path carrying an
  error body, and everything downstream — a "mark processed" stamp, a log row, an idempotency key —
  records the work as done.
- Found: 2026-09-30 — a booking-capture pipeline.
- **How this one got there is the lesson.** The node previously *threw*, and because n8n runs branches
  depth-first that throw starved a sibling branch (`POST to the internal event spine`). The fix applied was
  to stop it throwing. **A fix that converts an error into a non-error has not removed the failure — it
  has removed the evidence.** The correct shape is to branch on `statusCode` explicitly and alert, not
  to silence the call.
- Corollary for audits: **a finding goes stale.** The 2026-09-21 depth-first audit was restated as
  current on 2026-09-30 and was wrong — the capture had been clean since 2026-09-15. Re-check an audit
  note against live executions before acting on it, exactly as you would a claim about a live system.

### Estate-wide sweep 2026-09-30: many swallow-switch nodes — tier them by WHAT THE FAILURE FEEDS
Grepping for `neverError` / `onError: continueRegularOutput` returns **well over a hundred nodes**, and most are legitimate (a notify or log leaf *should* not halt a lead). The switch is not
the finding. **The finding is what the swallowed value flows into:**

- **Tier 1 — a call to another workflow's webhook.** A dead callee returns 404, gets swallowed, and the
  work silently never happens. **Verify every one with the GET probe above** — it answers "is the callee
  actually live?" in one request, with no execution and no side effect. Result 2026-09-30: of 8 such
  nodes, **7 callees live, 1 dead** (`Outreach — 02 :: Fire WF3` → Outreach-03, off; dormant, Outreach-02 has had zero
  executions in 30 days). Two others were dead until that evening's reactivations.
- **Tier 2 — the swallowed value feeds a node that DECIDES or RECORDS STATE.** This is the dangerous
  tier. Split it further, because the two halves differ in kind:
  - **feeds a RECORDER** (`Mark … Sent`, `Mark Processed`, an idempotency stamp) → the work is logged as
    done when it was not. Loses a record; often unrecoverable if the stamp blocks a retry.
  - **feeds a GUARD** → ⚠️ **worse: the guard fails OPEN and the unsafe action is taken.** Live example:
    `Webinar — Email Drip :: Fetch Contact (for tags)` (`neverError`) feeds `Already Enrolled?`,
    whose test is `($json.tags || []).map(t => t.name).includes(dedupTag)`. A failed Wealthbox fetch
    leaves no `tags`, so the test is **false**, the item takes the "not enrolled" branch, and the
    contact is **enrolled again — a duplicate email to a real prospect.** Compound (needs a double
    enrollment *and* a fetch failure), so not acute, but it is the shape to hunt for.
- **Tier 3 — terminal leaves / notify + log nodes.** The failure is invisible but nothing downstream is
  misled. Usually the intended use; leave them.

**The question to ask of any swallow switch: does the swallowed value feed something that DECIDES, or
something that merely RECORDS?** A logger loses a record. A guard takes the unsafe action. Sweep by that,
not by the switch name — and remember `neverError` and `continueRegularOutput` are two switches with one
effect, so grep for both.

### A guard that validates SHAPE but not the downstream system's CONTRACT passes garbage to a certain failure
- `Site — Lead Capture`'s `Is Valid?` tested honeypot + source allowlist + email *shape* — all reasonable — and
  never tested what Wealthbox actually requires. Wealthbox rejects a contact with no name (422), so every
  nameless submission cleared the guard and then died one node later. The guard was protecting the workflow
  from malformed input while handing the CRM input it was guaranteed to refuse.
- **Ask of any validation node: whose contract is it asserting?** A generic well-formedness check is not a
  guard on the system downstream of it. Validate against the schema of the thing you are about to call.
- Found: 2026-10-01 — a site lead-capture workflow.

### A PARTIALLY-effective bot filter CAMOUFLAGES the real bug behind it
- Six `gated-form` submissions arrived in one 30-second bot burst. The honeypot caught three;
  three got through and 422'd. The surviving sample therefore looked like *spam that slipped the filter*, and
  the obvious next move is "tighten the honeypot" — which would have fixed nothing and hidden a dead capture
  path on a live capture page indefinitely.
- The three honeypot-dropped and three passed submissions were **byte-identical except `submitted_at`**, which
  read as a non-deterministic guard until the bot's varying honeypot value explained it. That detour is the tell:
  when identical-looking inputs split across a guard, diff the FULL normalize output (incl. the `valid` flag),
  not the fields you expect to matter.
- **Generalizable: a filter's successes are camouflage for its misses.** When a guard catches *some* of a
  burst, do not reason about the survivors as "the ones that beat the filter" — ask why they were admissible
  at all, and what happened to them next.
- Found: 2026-10-01.

### Executions alone cannot tell you a capture path has NEVER worked — enumerate and group by source
- "Is this broken for everyone or just this one?" is answerable in a handful of API calls on a low-volume workflow:
  pull every retained execution, and for each print the normalize output's discriminator (here `source`) plus
  whether it reached the create node. Grouping those executions by source is what turned a handful of failures into
  "zero gated-form leads have ever reached the CRM, and the estimator ones did."
- Retention is the limit, and it is short (a few weeks here). **State the window with the claim** —
  "zero in the retained window" is honest; "never" is not, and the whole burst being one bot means there is
  *no evidence a real lead was lost*, only proof the path cannot work. Keep those two claims separate.

### The `neverError` + idempotency-stamp door finally bit — registrations silently un-enrolled
- The hazard documented above stopped being theoretical on 2026-10-01. `Webinar — Form Pipeline ::
  Trigger Email Drip` (`neverError: true`) POSTs to `<drip-webhook-path>`. That webhook was **dead**
  from a vendor hold until it was reactivated on 2026-09-30. Every registration in
  between got a **404 swallowed as success**, flowed down the happy path, and was stamped
  `Mark Processed - Success`.
- Found: 2026-10-01 — a webinar registration pipeline.
- **What makes this the expensive shape rather than an annoyance:** the people were captured, CRM'd,
  logged to the sheet and marked processed, so every downstream check says they are fine. The *only*
  way to find them is to read `Trigger Email Drip`'s own output per execution and look for
  `"is not registered"`. No error, no alert, no row missing, nothing red.
- Compounding factor worth remembering: Livestorm's own automated emails were carrying the
  registration confirmation during that window, so the gap was invisible from the recipient side too —
  until Livestorm's emails were switched off, at which point the affected registrants would receive
  **nothing at all** before the event.
- **Check this whenever a webhook callee is reactivated:** the reactivation fixes the future and does
  nothing for the backlog. Enumerate the executions from the outage window and diff "reached the
  trigger node" against "a matching execution exists in the callee."

### Measured outreach-pipeline topology 2026-10-01 — and a `head -20` that produced a false report
- Live: `00 Sheet Sync` (webhook, manually triggered), `01 Poller` (every 15 min, succeeds, finds nothing),
  `04 Bounce Handler`, `05 Suppress`, `06 Monitor`, plus the content workflows B/C/D.
  Off: **all four `03 — Resend Enroll` variants**, and `02 — Wealthbox Upsert` as of 2026-10-01.
- `outreach-enroll` is confirmed **dead** by the zero-side-effect GET probe. With `02` live that was
  an armed one-way door; `02` was deactivated rather than reviving `03`, because reviving it would
  resume real cold-outreach email on copy nobody had re-checked.
- ⚠️ **`06 — Monitor` alerts every 6 hours that leads are stuck in Processing and "WF3 may have
  failed". That is CORRECT** — WF3 *is* off. It had alerted on every retained execution, and the
  obvious move (silence the noisy monitor) would have destroyed a true signal about a real break.
  **Before muting a repeating alert, establish whether it is wrong.** A monitor that fires constantly
  because the thing it watches is genuinely broken looks identical to a broken monitor.
- **How the false report happened:** `tools/n8n ls outreach | head -20`. The listing sorts `○ off` before
  `● live`, so truncation hid every live workflow and produced a confident "the entire outreach-pipeline send chain
  is off." **A truncated listing is not a listing** — when a command's output is the evidence for a
  claim, count the rows against the real total before believing it.

### The LIST endpoint omits `description` — a scan for stale descriptions can only ever return empty
- `GET /api/v1/workflows?limit=250` returns `id, name, active, nodes, connections, settings, tags…`
  but **not `description`**. `GET /api/v1/workflows/{id}` does return it.
- So the obvious audit — pull every workflow once, grep the descriptions for "INACTIVE"/"DRAFT" —
  reports **zero hits on an estate full of descriptions**, and the zero looks like a clean bill of
  health. Caught 2026-10-01 only because a description had been written by hand an hour earlier and
  was known to exist; without that control it would have passed.
- **Same family as the jq `fromdateiso8601` trap above: a filter that is structurally incapable of
  matching returns "nothing wrong".** Prove any audit by forcing a known hit first.
- Correct method: iterate the ids and fetch each workflow individually (a few dozen live workflows ≈ seconds).
- MCP op shapes that are easy to get wrong, confirmed by trial 2026-10-01:
  `removeTags` / `addTags` take **`names`** (not `tags`, not `tagIds`, not `tagNames`);
  the description op is **`setWorkflowMetadata`** (not `setWorkflowDescription`), capped at 255 chars.

### Sweep for DISABLED NODES inside ACTIVE workflows — a capture-only restore is invisible from the dashboard
- The "disable the SEND node, keep the workflow active" pattern above is the right move under a hold,
  but it leaves **no trace at the workflow level**: the dashboard shows `active: true`, executions show
  `success`, and the error sweep is clean. The only way to find one is to read every live workflow's
  nodes and filter `.disabled == true`:
  ```sh
  jq -r '. as $w | .nodes[] | select(.disabled==true) | "\($w.name) :: \(.name)"'
  ```
- Result 2026-10-01: **three live workflows had a disabled Resend sender** — `Site — Estimator Report`,
  `VSL — Capture Pipeline`, and `Webinar — Post-Sync`. The first two were disabled under a vendor hold and were **not in the 2026-09-30 reactivation**, which covered only the webinar
  drip and the Calendly sequence.
- ⚠️ **Both were live capture paths whose page promised an email that was not being sent:**
  one promised a generated report, the other a video copy
- ✅ **RESOLVED 2026-10-01**, the archiving BCC having been proven that
  morning. Before re-enabling, each sender was checked against the live version — BCC to
  `archive@example.com` present, full footer (the required legal footer + postal address + unsubscribe), Resend credential still bound — then `setNodeDisabled: false`, publish,
  deactivate→reactivate flush (both are webhook workflows, and neither had parked executions, so the
  flush was safe). Verified: both `disabled=false` in the live version, both webhooks re-register on
  the GET probe, and a re-run of the disabled-node sweep returns only the deliberately-disabled `Webinar — Post-Sync` sender.
- **Rule: when a hold lifts, enumerate what the hold disabled — don't reactivate from memory.** A
  reactivation list written by a human will miss the quiet ones, because a disabled node never
  complains. Pair this sweep with the webhook GET probe: together they answer "is this path actually
  able to deliver?", which `active: true` does not.

### Disarming a swallowed-404 door by deactivating the CALLEE can ARM A NEW ONE one hop upstream
- 2026-10-01 the armed one-way door was `Outreach — 02 :: Fire WF3` → the dead `outreach-enroll`. It was
  disarmed by **deactivating `02`** (rather than reviving `03`, whose cold-outreach copy nobody had
  re-checked). Correct call — and it silently created the identical hazard one link up the chain:
  `Outreach — 01 — Sheet Poller` (live, every 15 min) fires `Fire WF2` at `outreach-crm-upsert` with
  `neverError: true`, and deactivating `02` is exactly what made **that** webhook dead.
- **The shape: in a chain A→B→C, deactivating B to protect C turns A→B into the same swallowed-404 the
  deactivation was meant to fix.** The door doesn't close, it moves. Every `neverError` /
  `continueRegularOutput` call *into* a workflow you deactivate becomes newly armed at that moment —
  so **after deactivating any workflow, re-run the Tier-1 sweep and GET-probe the callees.** The act of
  fixing is itself a trigger for re-auditing.
- Severity is NOT automatic, and the difference is worth measuring before panicking: this instance was
  **recoverable**, because the poller has **no `Mark Processed` node** — stamping lived in `02`. A lead
  would have stayed `Approved + Unprocessed` and re-fired every 15 min rather than being stamped done
  and locked out. Cost would have been a false success row in the Log tab every 15 minutes, forever,
  with no alert — bad, but not the unrecoverable shape. **Ask where the idempotency stamp lives before
  grading one of these; the stamp, not the 404, is what makes a door one-way.**
- ✅ **RESOLVED 2026-10-02 by deactivating the poller**. Chosen
  over removing `neverError` because the poller does nothing useful while `02` is off, and because
  removing `neverError` on a *live* caller to a *dead* callee converts silent failure into a loud one
  that floods `#ops` (the ordering trap above). Three gates checked first, all of which should be
  checked before deactivating anything: **(a)** no parked executions (`n8n waiting` filtered to that id)
  — otherwise deactivation is not a stop, see `resend.md`; **(b)** no webhook path on it, so no
  site page can break; **(c)** the near-identical second copy <workflow-id> confirmed already off
  and left untouched — two workflows share the name `Outreach — 01 — Sheet Poller`, so act by **id**.
- Verified by independent read, not by the `success: true`: `active: false`, and the Tier-1 sweep dropped from 6 nodes to 5 with **all five callees now
  probing live — zero armed doors in the estate.** Runtime proof for a *schedule*-triggered workflow is
  the absence of the next slot: last run `16:30Z`, deactivated `16:40Z`, and no `16:45Z` execution.
- **Re-check:** `tools/n8n ls outreach | grep -i poller` (both copies `○ off`), and re-run the Tier-1 join —
  list live nodes whose `parameters.url` matches `app.n8n.cloud/webhook` carrying `neverError` or
  `onError: continueRegularOutput`, then GET-probe **every** callee it names. ⚠️ Probe *all* of them: the
  first pass of this audit probed 4 of 6, found the one dead callee, and stopped — reporting a complete
  sweep on two-thirds of the evidence. Same family as the rule that a reviewer names the instance they saw, and the instance is not the scope. Finding the hit early is precisely when it feels
  safe to stop enumerating.

### This instance's `GENERIC_TIMEZONE` IS Pacific — so "timezone UNSET" is NOT a bug here (measured 2026-10-02)
- The Schedule-Trigger gotcha above is correct but **incomplete for this instance**, and the omission
  reads as an alarm. It says n8n falls back to `America/New_York` when there is no workflow timezone
  **AND** no `GENERIC_TIMEZONE` env var. It never recorded which way *this* instance is set — so the
  rule looked like a live 3-hour error on every schedule-triggered workflow with `settings.timezone`
  unset. **A conditional rule whose condition was never checked reads exactly like an unconditional one.**
- **Measured by execution, after predicting the opposite from config.** Three live workflows, three
  different cron hours, all firing at exactly their intended **Pacific** time:
  | workflow | cron | fires | = PDT | ET would be |
  |---|---|---|---|---|
  | `Ops — Daily Briefing (AI)` | `0 7 * * 1-5` | `14:00Z` | **7h** ✅ | 10h |
  | a weekly newsletter workflow | Mon 07:00 | `14:00Z` | **7h** ✅ | 10h |
  | a weekly review workflow | `0 19 * * 5` | `02:00Z` | **19h** ✅ | 22h |
  Five consecutive executions each on the first two, four on the third. Not coincidence.
- **Consequence: do NOT "fix" the live workflows with an unset `settings.timezone`.** They are
  already running at the intended Pacific times. Setting it per-workflow is harmless tidying, not a
  correction, and treating it as a correction invents work and risks touching a live graph for nothing.
- **Two separate claims that were being conflated:** `settings.timezone` unset ≠ the cron runs in the
  wrong zone. The first is a config observation; the second needs the instance default, which only an
  execution reveals. an earlier note flagged this workflow's
  unset timezone as "worth fixing" — moot twice over: the instance default is already Pacific, **and**
  that workflow is webhook-triggered with no cron at all.
- ⚠️ **Still true and unchanged:** a Code node's `new Date()` runs on the Node **process** clock (UTC) —
  that is a different layer from the cron's timezone and this finding does not soften it. Keep deriving
  the PT offset by reading `timeZoneName: 'short'`, never by assuming.
- **Re-check:** pick any schedule-triggered workflow with no `settings.timezone`, read its cron, and
  compare 4–5 real `startedAt` values against the intended local hour. If they line up with Pacific, the
  instance default still is. Config cannot answer this; only executions can.
