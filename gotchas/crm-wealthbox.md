# Wealthbox — gotchas & reference

Cross-project. The official API docs were wrong on three points below — trust
runtime behavior and the workspace export over the docs.

## Gotchas

### Custom-field write format (docs are WRONG)
- Docs say: `custom_field_values: [{ custom_field_id, value }]`
- Reality: `custom_fields: [{ id, value }]`
- Symptom: 200 OK but `custom_fields` comes back empty.
- Found: 2026-06-10.

### Task due field
- Docs use `due_date` in examples. API actually wants `due_at`.
- Found: 2026-06-10.

### Task `frame` is required, values undocumented
- `frame: 'specific'` is required and valid. Other valid values were undocumented.
- Found: 2026-06-10.

### Single-select custom fields need `custom_field_option_id`, not `value` — and reject the WHOLE PUT
- Docs/intuition: write a custom field as `custom_fields: [{ id, value }]`.
- Reality for **selectable** fields (single_select): you must send `custom_field_option_id`
  (the option's ID), NOT `value`. Sending `value` returns
  `"<Field>: custom_field_option_id required for selectable fields"` and **`success: false`** —
  Wealthbox rejects the *entire* contact update, so NO custom fields AND no tags are written.
- Especially nasty with `neverError: true` on the n8n HTTP node: the failure is swallowed and the
  workflow reports success while nothing was applied.
- Fixes: (a) make the field **Text** (can't convert in-place — delete + recreate → new ID), or
  (b) map your value → the option's ID and send `custom_field_option_id`.
- Found: 2026-06-17 — a cold-outreach drip pipeline.

### Tags are asymmetric read/write — and a PUT REPLACES the whole tag set
- **Read** (GET contact, or the `?email=` search result): tags come back as objects —
  `tags: [{ id, name }, ...]`. Extract names with `contact.tags.map(t => t.name)`.
- **Write** (PUT contact): send tags as **plain name strings** — `tags: ["src:purchased-data", "drip:bounced"]`.
- **A PUT with a `tags` key REPLACES the entire tag set** (it is not additive). To add/remove one tag
  without losing the others you MUST **read-merge**: read current names, compute the target set, PUT the
  full set. Omitting the `tags` key entirely leaves existing tags untouched (partial update).
- Canonical read-merge (drop one, add one), as used in WF2 upsert + WF4 bounce handler:
  ```js
  const existing = Array.isArray(contact.tags) ? contact.tags.map(t => t.name).filter(Boolean) : [];
  const tags = Array.from(new Set([...existing, 'drip:bounced'])).filter(t => t !== 'drip:active');
  ```
- Found: 2026-06-21 — a cold-outreach drip pipeline.

### `DELETE /v1/contacts/{id}` returns **200 with the contact body**, not 204 — don't read that as failure
- Symptom: deleting a contact returns `statusCode: 200` and a full contact object including `name`,
  `id`, `created_at`. It looks like the record is still there.
- Reality: the delete succeeded. Wealthbox strips the record and returns the **husk** — note
  `email_addresses: []` and `tags: []` are emptied while `name` survives. There is no 204.
- **The response alone cannot confirm a deletion.** Verify with an independent read (list contacts and
  count, or re-query the id). Deletion is irreversible, so this is the one place where "the API said OK"
  is not good enough.
- Pattern for a bulk delete: `options.response.response.fullResponse: true` + `neverError: true` so a
  failure returns its status code instead of throwing — every target is attempted and you get a
  per-record audit rather than "it stopped somewhere."
- Found: 2026-08-03.

### Purchased-list contacts carry the SOURCE-RECORD name, not the person's preferred one
- `src:purchased-data` records come from a purchased list, so `first_name`/`last_name` are the **registered owner on the source record**. A contact emailing as "Dee" can sit in the CRM as "Margaret" with the same
  address. Search opt-out requests by **email AND name fragments**, never name alone — a name-only
  lookup will miss the record and the opt-out silently fails.
- Found: 2026-08-03.

### Contact create REQUIRES first_name or last_name — a form with no name field cannot create a contact
- `POST /v1/contacts` with `{first_name: "", last_name: ""}` returns **422 `"First name or Last name must be provided"`**
  (generic n8n message: "Your request is invalid or could not be processed by the service" — the real text is in
  `.data.resultData.error.description`). An email address alone is NOT enough to mint a contact.
- **This makes a capture form structurally incapable of reaching the CRM if it collects no name.**
  `example.com/gated` (`src:gated-form`) collects a required checkbox and an
  *optional* email, and sends no `first_name` at all — so every emailed submission 422'd. Measured across the retained `Site — Lead Capture` executions (09-07 → 10-01): every `estimator` submission created a contact,
  **zero `gated-form` submissions ever did.**
- Fix that does not touch an approved page: fall back in the create body, don't tighten the guard.
  ```js
  last_name: first ? "" : ((email || "").split("@")[0] || "Unknown")
  ```
  ⚠️ **The tempting fix is the wrong one.** Adding `&& first` to the workflow's `valid` test would silently
  DROP every nameless lead — converting a loud 422 into the invisible-loss shape this repo keeps rediscovering.
  Make the record creatable; don't make the lead disappear.
- Found: 2026-10-01 — a site lead-capture workflow.

### A repeat registrant's name is OVERWRITTEN in the CRM by whatever they type into the form
- `Webinar — Form Pipeline`'s `Update Wealthbox Contact` sends `first_name`/`last_name` on the
  **existing-contact** branch, so a PUT rewrites the stored name with the form's values. The contact
  is matched on **email**, so this fires for anyone who registers twice.
- Found: 2026-10-03.
- **Why it matters:** a genuine repeat registrant who types a nickname, a
  maiden name, an initial, or a typo silently rewrites their own CRM record. Nothing alerts. The
  older record is only recoverable from the execution that overwrote it, and only inside retention.
- Same family as the purchased-data name gotcha above — in both cases the stored name is not the
  one you think, just from opposite directions: there the CRM holds a name the person never uses,
  here the CRM loses the name it had.
- ⚠️ Tags are NOT affected (they were `[]` before and after) — consistent with the create-only tag
  behaviour noted in `n8n.md`. It is specifically the name fields.
- **The safe shape** is to send name fields only on create, or only when the stored
  name is blank.

## Reference (stable facts)

> Project-specific custom-field IDs live in the project README, not here.
> This file holds *format* rules that are true across every project.

- Search order for upsert: by **email** first, then by **address**, then create.

### Merging duplicate contacts KEEPS BOTH email addresses on the survivor
- Found: 2026-09-24 — a booking-capture pipeline.
- **Why it matters:** `Leads — Sheet vs Wealthbox Reconcile` looks a lead up by
  `GET /v1/contacts?email=`, not by the Wealthbox ID stored in the sheet. Because both addresses
  survive a merge, **both sheet rows still resolve and the reconciler stays quiet.** If a merge ever
  dropped an address, the orphaned row would be reported as "in the sheet, missing from the CRM" — a
  false gap alert on a lead that is perfectly fine, and invisible from the sheet side because nothing
  there records that a merge happened.
- Corollary: the stored `Wealthbox ID` in a lead row CAN go stale after a merge (one of the two ids
  no longer exists). Nothing currently reads it back, but don't build a lookup on it — use the email.

### READ endpoints (contact + notes) — verified 2026-07-04
- Base `https://api.crmworkspace.com/v1`, header **`ACCESS_TOKEN: <token>`** (NOT `Bearer`).
- Contact by email: `GET /v1/contacts?email={email}` → contacts, each
  `{ id, first_name, last_name, email_addresses:[{address,principal,kind}], tags:[{id,name}] }`.
- Contact by id: `GET /v1/contacts/{id}` → a single contact object (bare, not wrapped).
- Notes for a contact: `GET /v1/notes?resource_id={contactId}&resource_type=Contact` → notes, each
  `{ id, body (HTML — apostrophes as &#39;), created_at, creator (user id), linked_to:{id,type,name} }`.
- Build defensive: tolerate `{contacts:[…]}`/`{notes:[…]}` vs bare-array vs single-object. Note `body`
  is HTML → strip tags + decode entities. Used by an internal tool's `/api/internal/crm` (an internal CRM proxy).
