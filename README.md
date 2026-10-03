# n8n field notes

**83 production failure modes in n8n, Google Sheets, Resend and the Wealthbox CRM API — with the
symptom that exposed each one, the cause, the fix, and how to prove the fix actually landed.**
Plus 5 reference sections of stable, hard-won API facts (88 entries in total).

This is not a tutorial and not a summary of the docs. It is an operating log kept while running a
production n8n estate that handles lead capture, multi-step email sequences, CRM upserts and
ad-platform conversion reporting. Entries were written at the moment something broke, which is why
they read the way they do.

| file | entries | what it covers |
|---|---|---|
| [`gotchas/n8n.md`](gotchas/n8n.md) | 67 | execution order, versioning vs runtime, Code nodes, waits, concurrency, swallowed errors |
| [`gotchas/crm-wealthbox.md`](gotchas/crm-wealthbox.md) | 11 | Wealthbox, whose docs were wrong on three counts |
| [`gotchas/resend.md`](gotchas/resend.md) | 7 | rate limits, parked executions that keep sending, deliverability |
| [`gotchas/google-sheets.md`](gotchas/google-sheets.md) | 3 | quota behaviour, outages, schema drift |

Dates span 2026-06-10 to 2026-10-03.

---

## The discipline this encodes

One idea generated most of these entries:

> **Verify the claim, not its proxy.**
> `active: false` is not proof nothing sent. A recent fetch is not proof of a push. A documented
> footer is not proof of an implemented one. A rename is not done until you grep for the old name.

Most things that went wrong were **true when recorded and quietly stopped being true.** So every
entry that describes live behaviour also records *how to re-check it*, and the recurring theme is
that structural verification is not enough:

- `versionId == activeVersionId` proves the **database**, not the **running graph**. Only an
  execution proves the runtime.
- `appliedOperations: N` counts operations *attempted*, not effects *realized*.
- A monitor returning "nothing wrong" is indistinguishable from a monitor that is structurally
  incapable of matching anything. **Prove a filter by forcing it to match**, never by watching it
  come back empty.

## Start here

If you only read five, read these — they generalize past n8n:

1. **[Branches run depth-first](gotchas/n8n.md)** — two targets on one output are *not* parallel.
   If the first chain throws, the second target never executes at all: no error, no trace. So a
   "fire-and-forget" side branch is a myth unless it is ordered **first**. Proven both ways, with a
   successful run showing the ordering and a three-week outage showing the cost.

2. **[`neverError: true` makes `retryOnFail` dead code](gotchas/n8n.md)** — and hands the failure
   downstream as a success, where a "mark processed" stamp records the work as done. Combined with
   an idempotency key, two individually-reasonable mechanisms become a one-way door: the record is
   marked complete, a retry is rejected as a duplicate, and nothing is red.

3. **[Deactivating a workflow does not stop it](gotchas/resend.md)** — parked executions resume on
   their `wait` schedule and send for real. Deactivation closes the front door only. For a legal or
   compliance hold, "paused" is false until the queue is empty.

4. **[Idempotency keys must never include a client timestamp](gotchas/n8n.md)** — a timestamp is the
   one field guaranteed to differ between a request and its retry, which is exactly the case the key
   exists to catch. Includes the companion trap that fixing it creates.

5. **[jq `fromdateiso8601` cannot parse n8n timestamps](gotchas/n8n.md)** — and the defensive idiom
   `fromdateiso8601? // 0` converts a parse error into a *wrong answer*: every row is excluded and
   the monitor reports clean forever. The check written because something failed silently was itself
   silently dead for weeks, and looked healthy the whole time.

## How an entry is structured

Entries are a log, not a template, so the shape varies with what the failure needed. The common
form is:

```
### One-line statement of the failure, specific enough to grep for
- Symptom:  what you actually observe, including what looks fine
- Cause:    the mechanism, not the guess
- Fix:      what to do instead
- Found:    date — the kind of workflow it surfaced in
```

In practice `Symptom` appears in 38 entries, `Cause` in 29, `Fix` in 39 and `Found:` in 72 —
the rest are written as straight prose where the bullet form would have padded them. Verification
is usually folded into the Fix rather than given its own line. A handful of entries describe a
hazard found by audit before it ever fired, so they have a mechanism and no fix.

Several entries contain a correction to an earlier entry, with the measurement that forced it.
Those are deliberate: a finding goes stale, and an audit note restated as current is how you act
on something that stopped being true. Where a claim is reasoned rather than observed, it says so.

## Tools

Both are read-only and timeout-bounded.

- **[`tools/n8n`](tools/n8n)** — a read-only CLI over the n8n public API: list workflows, inspect a
  workflow or a single node, read recent executions, group failures by workflow, list every
  registered webhook, show parked executions, and probe whether a production webhook is live
  **with zero side effects** (a `GET` distinguishes "is not registered" from "not registered for GET
  requests" without starting an execution). Read-only is the design, not a limitation — mutations
  belong somewhere reviewable.

- **[`tools/preflight.sh`](tools/preflight.sh)** — a session check that is **quiet on success**. It
  answers three questions: is any work only on this laptop, does every webhook the site calls have
  an active workflow listening, and is anything failing repeatedly. The second is the one no
  dashboard shows you — both halves look healthy alone.

```sh
export N8N_BASE="https://your-instance.app.n8n.cloud"
echo 'your-api-key' > ~/.n8n-api-key && chmod 600 ~/.n8n-api-key
tools/n8n ls
tools/n8n probe some-webhook-path
```

## A note on what was removed

These notes were kept while working on real client systems, so this public version has been
sanitized: names, email addresses, workflow and credential IDs, execution numbers, instance
hostnames, Slack channel IDs, webhook paths and private repo paths are gone. Where a real name
taught something — a one-character surname mismatch defeating an exclusion filter, a contact stored
under a name they never use — it was replaced with a fictional one that preserves the lesson.

Business-scale figures (CRM size, campaign sizes, lead volumes) and references to specific business
events have been generalized, and passages that described real operational incidents have been
rewritten in the mechanism voice — what fails and why, rather than what it cost anyone. Counts that
are purely internal to n8n (how many nodes a sweep returned, how many times a workflow failed) are
kept where they carry the argument, since they say nothing about anyone's business.

What is kept is the mechanism, the fix, and the verification method — which is the whole of the
technical content. Vendor names (n8n, Google Sheets, Resend, Wealthbox, Livestorm, Calendly, Meta)
are kept because they are products, not identities, and the behaviour described is specific to them.

## License

MIT — see [LICENSE](LICENSE). Use them, copy them, and if one saves you a bad afternoon, good.
