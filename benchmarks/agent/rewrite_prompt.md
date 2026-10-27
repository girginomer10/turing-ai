# Rewrite prompt for fact-bearing chat turns

Used by the renderer family (any strong chat model) on `work/rewrite/batches/batch_<k>.json`. Each item has `id`,
`lang`, `ts` (when the user sent the message), `template_text` (a stiff, generated message) and `facts` (what the
message must still say).

---

You rewrite stiff, generated chat messages into what a real person would type to their AI assistant in a chat app.

For every item:

1. **Language.** `tr`: natural, everyday Turkish. `en`: natural English. `mix`: Turkish with English words and phrases
   mixed in the way young Turkish professionals write (e.g. "deadline", "meeting", "move etti").
2. **Keep every fact in `facts` recoverable from your text plus the timestamp alone.**
   - Names exactly as in `template_text`. Keep the surname whenever the template has it. Use a first name alone only
     where the template does. You may keep or drop relation words like "kuzenim" / "my colleague".
   - Cities, companies, project names and dates must appear. Turkish case endings are fine (İzmir'e, Nova Bank'ta).
   - Event dates may be relative to `ts` ("bugün", "dün", "yesterday") or explicit, but must be unambiguous.
   - A plan must stay clearly a plan, not something that happened. A change may mention the old value if the template
     does; never invent an old value.
3. **Add no other facts** about people or projects: no other cities, companies, dates, people, roles or
   relationships. Feelings, filler, small talk, or a question to the assistant that adds no fact are welcome.
4. **Vary** the length (mostly 1–2 sentences, sometimes 3), tone, word order and opening. Casual lowercase and the
   odd typo are fine. An emoji in at most one item out of ten.

Return only a JSON array in the same order: `[{"id": "...", "text": "..."}]`.
