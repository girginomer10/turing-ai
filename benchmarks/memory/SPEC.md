# Synthetic personal-memory benchmark: authoring spec

Goal: a fictional-but-realistic personal memory store per persona, plus queries with known answers, to measure what
the app's recall actually does with *personal* material (short facts, dated events, chat messages, document chunks),
not encyclopedic text. Everything is invented: no real people, no real contact data, nothing sensitive.

## File format (one JSON file per persona: `data/persona_<n>.json`)

```json
{
  "persona": "p1",
  "summary": "one-line description of the invented person",
  "items": [
    {"id": "p1-m001", "kind": "topic", "lang": "tr", "title": "Short title", "text": "...",
     "age_days": 120, "confidence": 0.8, "importance": 0.6, "container": "p1-c001"}
  ],
  "queries": [
    {"id": "p1-q001", "type": "paraphrase", "lang": "en", "text": "...", "gold": ["p1-m014"], "note": "why this is the answer"}
  ]
}
```

### Item kinds (they mirror what the app stores)
* `topic`: a consolidated lasting fact written in third person about "the user" (1-2 sentences), e.g.
  "The user's sister Elif works night shifts as a nurse in Izmir." Own container each. confidence 0.6-0.95, importance 0.3-0.9.
* `event`: a dated personal report, e.g. "On 12 March the user said they have a dentist appointment on Friday." Own container.
  Include a concrete date or time cue in the text. confidence 0.5-0.9.
* `message`: a past user chat message, first person, conversational, 1-4 sentences, may be messy (typos, abbreviations,
  Turkish/English code-switching). Messages from the same imaginary conversation share a container (2-5 messages per
  container). No confidence/importance (use null).
* `document`: a chunk (2-5 sentences) from an imported document (lease clause, course syllabus, recipe, warranty, trip
  itinerary, insurance policy, meeting notes). Chunks of one document share a container. confidence/importance null.

Per persona: 60-75 items total. Mix: ~20 topics, ~12 events, ~25 messages, ~10 document chunks.
Language of the stored text: about 50% Turkish, 40% English, 10% code-switched (set `lang` to the dominant one;
use `"mixed"` for code-switched). `age_days`: 1-900 (events mostly 1-120).

### Query types and counts per persona (about 45 queries)
| type | n | definition |
|---|---|---|
| `direct` | 7 | the user re-uses the item's own key words ("what is my wifi password at the cabin") |
| `paraphrase` | 12 | same meaning, **at most one shared content word** with the gold item (no names/numbers copied unless unavoidable) |
| `cross_lingual` | 10 | query language differs from the gold item's language (Turkish query for English item and vice versa), paraphrased |
| `hard_negative` | 9 | a *near-duplicate distractor exists* (same template, other person/date/place/amount); only one item is correct and the query must contain what disambiguates it |
| `unanswerable` | 7 | plausible personal question that **no item answers** (adjacent topic exists in the store, but not the asked fact); `gold` is `[]` |

Queries are what a real user would type to an assistant mid-conversation: natural, sometimes vague, 4-25 words.
`lang` is `tr` or `en`. Balance languages roughly 55% Turkish / 45% English.

### Hard requirements
1. Every non-unanswerable query has exactly **one** gold item that really contains the answer; no other item may
   answer it equally well. Near-duplicate distractors must differ in the fact the query asks for.
2. At least 40% of items are never gold for any query (distractors/noise). Include >= 10 deliberate near-duplicate
   pairs/triples across topics/messages/documents (e.g. two relatives' birthdays, two dentist appointments, two flats'
   deposits, two similar courses).
3. Do not leak the answer in the query. Paraphrase/cross-lingual queries must not copy rare words from the item.
4. Facts must be internally consistent within a persona and varied (family, work/study, health-lite, hobbies, money,
   travel, home, food, pets, plans). Keep it wholesome; no medical diagnoses, no explicit content.
5. Names, places and numbers are fictional-plausible (Turkish names for Turkish contexts, etc.).
6. IDs: items `<persona>-m001...`, queries `<persona>-q001...`, containers `<persona>-c001...`. `kind`, `lang`, `type` use
   exactly the values above. Valid JSON only, UTF-8, real Turkish characters (ç ğ ı ö ş ü).
7. Write the file with your own words; do not copy from any dataset.
