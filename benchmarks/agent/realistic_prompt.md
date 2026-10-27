# Writer prompt for the realistic chat surface

Used by the session writer on `work/realistic/batches/batch_<k>.json`. Each item is one chat session to write.

---

You write realistic chat sessions between one person (the "user") and their AI assistant, as they would appear in
the person's chat history. The sessions are synthetic test data about fictional people, used to test how well a
search system finds information spread across a long, messy archive. Write them like real chats: people type
casually, refer back to earlier lines, use pronouns and first names, leave things implicit, mix topics and make
small typos. The assistant answers helpfully and naturally, in the same language, at a realistic length (usually
1–4 sentences, longer when the user asks for real help such as code or a plan).

Each item gives:
- `session_id`, `date` (the day the chat happens, with weekday), `lang` (`tr` Turkish, `en` English, `mix`
  Turkish with English mixed in the way young Turkish professionals write), `persona` (the user's style, not
  facts to state), `user_turns` (about how many user messages to write);
- either `facts` (things the user must tell the assistant in this session) or `topic` (a session with no facts
  about the people in their life), and sometimes `mention` (a person or project to mention without stating any
  fact about them).

## Fact sessions

Weave every fact into a natural conversation that also has another purpose: asking for advice, planning,
venting, getting help with a message or a task. Follow each fact's instructions exactly.

- **Names.** `name` says how the person must be referred to when introduced. "full" means write the full name
  (first + last) at that point, because another person shares the first name. "first" means the first name alone
  is enough (the full name is also fine). Never invent nicknames. Never introduce a person only by a relation
  ("my cousin") without the required name. Project names and company names must appear as given (Turkish case
  endings are fine: Vega'nın, Nova Bank'ta).
- **Split facts** (`split: true`). Introduce the person (and the project, if any) in one user message that does
  NOT yet state the fact, for example "Elif'le konuştum bugün" or "remember Mert from the gym?". State the fact in
  a LATER user message without repeating the name: use a pronoun, Turkish pro-drop ("İzmir'e taşınmış") or "she
  / he / they". Nothing in between may introduce another person the pronoun could refer to.
- **Not split.** The name and the fact can be in the same message, or the fact can follow right after the name.
- **Dates.** Follow `when` literally. A relative expression (today, yesterday, a weekday) must refer
  unambiguously to the date given. When it says "day and month", write the day and month (add the year only
  where it says so).
- **Changes.** For a change (a move, a new job, a new lead, a new deadline), say clearly that it is new or
  current. Mention the old value only where the fact allows it. For a new project lead, do NOT say what the
  previous lead does next. Do not say they left the team or moved to another project.
- **Plans.** A plan must stay clearly a plan: considering, maybe, not decided.
- **No other facts** about named people or projects: no extra cities, employers, roles, team changes, deadlines,
  meetings or trips. You may add the user's own feelings, small talk, and requests for help.

## Topic sessions (no facts)

Write a natural chat on the topic: coding help, cooking, health, travel ideas, money, writing, studying, and so
on. If `mention` is given, mention that person or project in passing exactly as instructed (asking for gift
ideas, drafting a message, getting help with slides) without stating where anyone lives or works, who leads
what, who is on a team, any deadline, or any meeting, meal or trip with them.

## Annotations (required)

For every user message, list the fact ids it contributes to:
- `conveys`: the message states the fact's content (the city, company, date, team change, event...).
- `names`: the message introduces the person or project that a later message's fact refers to (split facts).

A fact that is not split has its id in `conveys` of the message that names the person and states the fact.
Assistant messages and messages without facts have empty lists. The assistant must not be the only place a fact
is stated.

Return only a JSON array with one object per item, in the same order:
`[{"session_id": "...", "turns": [{"role": "user", "text": "...", "conveys": [...], "names": [...]}, {"role": "assistant", "text": "...", "conveys": [], "names": []}, ...]}]`
