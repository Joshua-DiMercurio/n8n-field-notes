# Resend — gotchas & reference

Cross-project.

## Gotchas

### Resend caps at 10 requests/second — and `wait` nodes resuming on absolute clock times manufacture the burst
- Symptom: a drip silently delivers an **incomplete sequence** to a subset of recipients. The execution
  status is `error`, not a send failure you'd notice — and because a dead execution never reaches its
  later `wait` nodes, **one 429 costs that lead every remaining email in the sequence**, not just the one.
- Cause: n8n `wait` nodes resume at an **absolute wall-clock instant**. Every execution scheduled for
  "8 AM the day before" wakes in the *same millisecond*, so a cohort of N leads fires N simultaneous
  POSTs at `api.resend.com/emails`. Everything past the 10th in that second gets
  `429 — "You can only make 10 requests per second."` Adaptive/compressed scheduling does **not** help:
  it only sorts people into a handful of identical instants, which is exactly the herd.
- The tell-tale in `get_execution`: `lastNodeExecuted: "Send Email N"`, `httpCode: "429"`, and n8n's own
  hint `"Try spacing your requests out using the batching settings under 'Options'"`.
- Fix: **`retryOnFail: true, maxTries: 5, waitBetweenTries: 5000`** on every Resend HTTP node (MCP op is
  `setNodeSettings`). A 429 is a **pre-send rejection** — Resend never queued the message — so retry
  **cannot double-send**. This is the same reasoning that makes the Sheets-429 retry safe.
- Capacity math worth knowing: n8n's retry delay is **fixed, not jittered**, so a herd retries in
  lockstep and drains ~10 per attempt. `maxTries: 5` therefore covers a burst of **~50**. Past that you
  need real throttling (`splitInBatches` + `wait`), not retry.
- **`onError: continueRegularOutput` turns this into SILENT loss.** On WF-N2's `Send Resend` the 429 was
  swallowed, the run reported success, and the row was still stamped `Sent` — recipient never emailed,
  never will be, no error anywhere. Identical shape to the Sheets append-drift amplifier in `n8n.md`.
- **Sibling of the Sheets 429 gotcha in `google-sheets.md`, and the lesson did not transfer** because it
  was filed under the *vendor* (Google Sheets) instead of the *pattern*: **any fan-out into a
  rate-limited API needs retry on the call**. When you fix one, grep for the others the same day.
- Found: 2026-08-11 — a webinar registration pipeline.

### Waiting executions are pinned to their snapshot — so a retry fix CANNOT rescue an in-flight cohort
- Corollary of the "publishing does not change waiting executions" rule in `n8n.md`. Adding `retryOnFail`
  helps only executions that **start** after the publish. Anything already parked between `wait` nodes
  runs to completion on the graph it started on.
- Practical consequence: **there is no same-day fix.** Discovering this on send day means the current
  cohort is already decided; the fix protects the *next* one.
- Second-order trap: **do not `unpublish → publish` (the runtime-flush step) while executions are
  waiting.** **Drain the queue first** (`search_executions status=waiting`, check the latest `waitTill`),
  then flush, then verify by a live execution. Deferred exactly this way on 2026-08-11 with executions still parked.

### ✅ RESOLVED 2026-09-04 — deactivating does NOT cancel parked executions. THEY KEEP SENDING.
- This file previously said it was "unverified whether deactivating cancels parked executions" and
  feared the blast radius was *lost* emails. **It is the opposite, and worse.** A deactivated workflow's
  in-flight executions resume on their `wait` schedule and **send for real**.
- Found: 2026-08-18 — a multi-step email drip.
- **Deactivation only closes the front door.** It stops the trigger accepting NEW work; it has no effect
  whatsoever on executions already inside. Pairs exactly with the pinned-snapshot rule in `n8n.md`: a
  parked execution is both *unstoppable* and *frozen on its old graph*.
- **Consequence for any hold: deactivating is NOT a stop.** It reads like one on the
  dashboard — `active: false`, no new runs — while real messages keep going out for days. A dashboard reading `active: false` is not evidence that sending has stopped.
- **To actually stop sending, you must do BOTH:** deactivate AND drain or kill the parked executions
  (`search_executions status=waiting` → stop each in the UI). **Verify by the absence of new sends**, not
  by `active: false`.
- **A pause also silently un-does later hardening.** The auto-BCC to `info@` was added only after an
  earlier cohort had already drained — so those sends never carried it. The snapshot pin means a parked
  execution can never pick up a fix you make while it waits.
- Found: 2026-09-04.

### The footer requirement was documented but not implemented — audit the LIVE node, not the doc
- The "physical address required" rule above has been in this file the whole time. It was still **missing
  from every webinar-family email** until 2026-07-28: `Webinar — Email Drip` (3 Build Email nodes) and
  `WF-N2 — No-Show Send` (1). `Outreach — 03` had it. So one family complied and the other didn't, for months.
- Why it hid: a stale in-repo mirror of the workflow self-identifies as
  stale, and WF-N2's **n8n description** claimed "DRAFT / TEST_MODE=true / Not published" while the
  workflow was active, `TEST_MODE=false`, and had already sent real email. Both artifacts drifted toward
  looking *safer* than reality. The description is the most dangerous of the two — it's what a human reads.
- **Rule: a compliance-footer claim is only true if you have read it out of `activeVersion` today.**
  `jq '.workflow.activeVersion.nodes[] | select(.name=="Build Email") | .parameters.jsCode'` — and check
  `versionId == activeVersionId` first, or you're reading a draft.
- Fixed by inserting the address immediately before the required legal footer, matching the reviewer-approved outreach-pipeline copy. Found 2026-07-28.

## Reference (stable facts)

- **Domain verification gates real sends.** SPF + DKIM + DMARC must show Verified
  before sending from the real domain. DNS can take minutes to hours — start it first.
- **Compliance footer is required** on every send: a required legal footer, affiliation, physical address, working unsubscribe. Lives on the
  approved copy only.
- **Suppression check before send** (CAN-SPAM). Skip any address on the Suppression
  tab; unsubscribe link must write back to it.
- **Test-inbox override pattern:** hard-pin `to:` to your own inbox behind a
  `TEST_MODE` constant so a misconfig can't blast real contacts. Remove only at go-live.
- **Warm up the domain:** start with a handful of real sends, scale over days.

### Domain / DNS layout (example.com) — verified 2026-07-13
- **DNS is managed at GoDaddy** (nameservers `ns45/ns46.domaincontrol.com`) — add any Resend
  records there, NOT at Vercel/Cloudflare. GoDaddy's dashboard "pending" lags reality; trust `dig`
  against the authoritative NS (`dig +short CNAME <host> @ns45.domaincontrol.com`).
- **Resend sends from the `send.example.com` subdomain** (AmazonSES, region **us-east-1 /
  North Virginia**; MX `feedback-smtp.us-east-1.amazonses.com`, SPF `include:…send.example.com`).
  Keep any new Resend region choice on North Virginia to match.
- Root `example.com` mail = **Microsoft 365 / GoDaddy** (`info@…`), separate from Resend
  sending. DMARC on the org domain is `p=quarantine` with **relaxed** alignment (adkim=r/aspf=r),
  so a DKIM signature from `send.` aligns with a `From: @example.com` — no conflict.

### Click/open tracking — set up 2026-07-13
- **Tracking domain: `track.example.com`** — CNAME → `links1.resend-dns.com` → CloudFront.
  Verified in Resend; HTTPS/cert serving. (A bare `GET /` to the tracking root returns CloudFront
  `400` — that's normal; it only answers real wrapped-link paths.)
- **Decision: click tracking ON, open tracking OFF.** Open tracking is unreliable — Apple Mail
  Privacy Protection pre-loads the 1×1 pixel (inflates opens), image-blockers deflate it; Resend
  itself warns. For any sender, score engagement on **clicks (a real action), never opens.**
- **What wrapping does:** once click tracking is on, Resend auto-rewrites **every http/https link**
  in a Resend-sent email to redirect through `track.example.com`. `mailto:`/`tel:`/`#anchor`
  are NOT wrapped; unsubscribe still works. **Only the href is rewritten — visible text/approved
  copy is unchanged, so it is NOT a change to reviewed content** (gave the reviewer a courtesy heads-up).
- **✅ LIVE as of 2026-07-13 — toggle is ON.** End-to-end test passed: a test email with a Calendly
  link → link wrapped through `track.example.com` → click registered in Resend (Emails/Logs
  "Clicked" event). Open tracking left OFF (correct — MPP inflates opens). The toggle was left ON
  **deliberately** so the next task has click data live (superseded the earlier "wait until after the
  webinar" plan).
- **Toggle is account/domain-wide + forward-only:** it wraps every `http`/`https` link in **every
  Resend send across all workflows** (outreach-pipeline drip, webinar, VSL, Broadcasts) from the moment it's on —
  not retroactive to already-delivered mail. **Wrapping happens at SEND time**, so in-flight drips get
  their *remaining* sends wrapped too (a outreach-pipeline lead mid-sequence gets Emails 4–6 wrapped). This means
  that event's sends will have wrapped links — accepted (href-only, not a reviewable content change; `mailto`/`tel`/`#anchor`/unsubscribe never wrapped). Courtesy heads-up to the reviewer
  that email link-tracking is live is appropriate (not a re-approval).

### ✅ Resend DOES honour `bcc` on the send API — proven 2026-10-02 on real production sends
- Open and explicitly unproven since the 2026-08-26 auto-BCC build, which recorded: *"this does NOT
  prove that Resend's real API actually honors `bcc` at send time… don't claim it works until that
  happens."* **It now does.** Copies are confirmed landing in `archive@example.com`
  from real Email 1 sends of a webinar drip (2026-09-30 → 10-02).
- Shape that works, injected at the **HTTP-request layer** rather than in the upstream email-building
  Code node, so one edit covers every message the node sends:
  `={{ JSON.stringify(Object.assign({}, $json, { bcc: 'archive@example.com' })) }}`
  (some senders use a bare-object variant with no `JSON.stringify` — match the workflow's convention).
- **A `{"id": "<uuid>"}` response proves Resend ACCEPTED the request — it does not prove the bcc copy
  was delivered, and it certainly does not prove it was archived.** Three distinct claims, and only a
  human looking in the destination can settle the last two. The execution data cannot help: n8n does
  not retain an HTTP node's resolved request body, so you cannot read the bcc back out of a run.
- **Auditing coverage: extract the `bcc` KEY, not the first email-shaped string in the params.** A loose
  `grep -oE '<email regex>'` over a node's parameters returns the **`from`** address first and will
  report a correctly-configured sender as pointing somewhere else. Cost a near-miss false finding
  2026-10-02 on `Site — Estimator Report` (`from: reports@…`) and `VSL — Capture Pipeline`
  (`from: info@…`) — both bcc the archive address correctly.
- Note that
  **archive capture in an outbound-mail archive remains a separate, still-open verification.**
