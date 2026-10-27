# Natural archive surface

Rewrite the supplied synthetic user messages as natural chats with an AI assistant. This is a controlled surface
change: the facts, referents and times must stay the same, but the wording must be independently composed.
Do not run tools, read files, delegate, or explain your work. Return the requested JSON directly.

Each item contains `id`, `lang`, `ts`, `template_text`, `facts`, and `kind` (`fact` or `distractor`).

## Compose, rather than lightly paraphrase

Read the facts, understand the change, then express it in your own words. Do not reuse the template's main verbs,
stock opening, clause order, or distinctive phrases. Changing just an adjective or adding an opener is insufficient.
In particular, do not make every project-lead update share one replacement phrase. Vary how responsibility, a
completed move, a job change, a deadline, a team change, or a shared event is explicitly communicated. Meaning must
remain clear without another message. Do not replace an explicit fact with an implication or vague pronoun.

Vary length and rhythm within the batch. Some messages should be compact; some should be two to four sentences,
with incidental chatter before or after the fact. Chatter may express the speaker's mood or ask the assistant for
help; it must not introduce a checkable biographical fact, event, or relationship. Do not meet the wording goal
merely by padding an unchanged fact sentence. Occasional lowercase, missing punctuation or a minor typo is welcome,
but never corrupt names, dates or the factual meaning. Avoid giving every message the same casual style.

## Preserve the evidence exactly

- `tr`: everyday Turkish. `en`: everyday English. `mix`: natural Turkish/English code-switching.
- Keep **every** fact in `facts`, and no additional fact about any named person or project. Every fact must be
  recoverable from this message and `ts` alone. A current employer is an employer, not a customer; living somewhere
  is residence, not a visit; leading a project is responsibility for it, not merely being a team member.
- Keep the exact proper names as written in `template_text`, including diacritics. Keep a full name wherever the
  template has a full name. Keep a bare first name wherever the template has only that first name: **do not expand
  it using the full name in `facts`**. Do not drop a named attendee, invent a surname or replace a required name with
  a pronoun. Relation words such as "kuzenim" or "my colleague" are optional; do not invent a different relation.
- Keep every project, company and city named in the template. Turkish suffixes are fine. Retain the template's
  spelling of city names even if a fact description uses the English equivalent.
- If the template explicitly names a previous employer, city or lead, retain it with the same former/current
  distinction. Never invent a previous value or an additional change. `changed` is metadata, not a new event.
- A plan to move must remain an unrealised plan; never make it a completed move or a confirmed commitment. An
  event must remain an event that happened, with all attendees, the same activity, city and optional project.
- Keep event dates and deadlines unambiguous relative to `ts`. Explicit dates with the year are safest. "Yesterday"
  or "dün" is allowed only when it resolves to the same date. Do not substitute an approximate period or invent a
  date for a change whose date the template did not state.

## Name-mention distractors

When `kind` is `distractor`, `facts` is empty. Keep naming the same person or project, with the same full-name or
first-name form as the template. Write a request or hypothetical question that asserts **no fact about them**:
no residence, job, responsibility, membership, deadline, meeting, preference or other biographical detail. Do not
turn a request for an agenda into a meeting that happened. Do not assert an upcoming birthday or book recommendation
just because the old distractor did. Relation words already in the template may be kept or dropped.

Output **only** one JSON array, with exactly one entry for every supplied ID, in the same order:
`[{"id": "w1/m00012", "text": "..."}]`. No Markdown fences, omitted IDs, repeated IDs, or extra keys.
