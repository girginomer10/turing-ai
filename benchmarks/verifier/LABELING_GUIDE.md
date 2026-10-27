# Labeling guide: is a proposed memory supported by the user's message?

You will see rows with three parts: the **user message** (one message, with its time), an optional **existing memory** that the
proposal would update, and the **proposed memory** (title + content) that the app's extraction model wants to store.
Decide whether the proposed memory is justified by what the user said **in that message**.

You are checking consistency with the user's words, not real-world truth. If the user says they live on the Moon, a memory
"user lives on the Moon" is *supported*.

## Labels (pick exactly one)

| label | meaning | typical cases |
|---|---|---|
| **supports** | The message, read plainly, states or directly implies the proposed memory. Paraphrase, translation and reasonable compression are fine. | "Üç yıldır Berlin'deyim" -> "Kullanıcı Berlin'de yaşıyor" |
| **insufficient** | The message does not say it. The memory adds, generalises, or assumes something the user did not state: ownership from an encounter, a fact from a plan, the user's own attribute from a relative's, a date the user never gave, a permanent habit from one event. | "Sokakta iki yavru kedi buldum" -> "Kullanıcının iki kedisi var" |
| **contradicts** | The message explicitly says the opposite of the proposed memory (negation, quitting, a correction, a different current value). | "Artık kahve içmiyorum" -> "Kullanıcı her gün kahve içer" |

Rules of thumb:

* **Plan vs fact.** "Paris'e taşınmayı düşünüyorum" supports "plans/considers moving to Paris", not "lives in Paris" (insufficient).
* **Other people.** "Kız kardeşim Berlin'de çalışıyor" supports a memory about the *sister*; "user works in Berlin" is insufficient
  (wrong person), not contradicts, because the user said nothing about their own job.
* **Time scope.** "Geçen yıl Lyon'da yaşıyordum" supports "lived in Lyon last year"; "current city is Lyon" is insufficient unless
  the message says it is still true; if the same message says "şimdi İzmir'deyim", then "current city Lyon" is contradicts.
* **Negation.** "Vejetaryen değilim" -> "user is vegetarian" is contradicts; "user does not eat red meat" needs that statement to be
  present, otherwise insufficient.
* **Encounters and events.** Finding, visiting, borrowing, seeing are events; they do not support ownership or an ongoing
  commitment. An *event* memory ("found three kittens on the way home") is supported if the message reports it.
* **Resolution of an event.** "Kedileri sahiplendirdik" supports updating the kitten event to "rehomed"; it does not support
  "user owns kittens".
* **Conditionals and hypotheticals.** "If I get the visa I will move" -> "user will move" is insufficient; "user may move if visa
  granted" is supports.
* **Corrections.** When the user corrects an earlier statement ("aslında kuzenim değil, abim"), the corrected value is
  supported and the old value is contradicted *if the proposal states the old value*.
* **Updates to an existing memory.** The *existing memory* column is context only. Judge the **new** content against the message.
  An old wrong memory cannot make a new proposal supported. Example: existing "user lives in Izmir", message "I'm in Istanbul
  now", proposal "user lives in Istanbul" -> supports. Same message, proposal "user lives in Izmir" -> contradicts.
* **Partial support.** If the proposal bundles two claims and the message supports only one, label **insufficient** and tag
  `other` with a note; the memory should be atomic.
* **Carry-over in updates.** Many updates restate the existing memory and add something new ("sister is a nurse in Ankara
  *and is exhausted from double shifts*"). Judge the **new or changed** part against the message. The restated part is
  inherited from the existing record and is not re-judged, but it must not be contradicted by the message and it must not
  be used to justify the new part. Label `supports` when every new claim is in the message; tag `carryover` so we can
  count these. If the "new" content is only the old memory restated with nothing from the message, label `insufficient`,
  tag `carryover`.
* **Pronouns resolved from memory.** "She's a lawyer" -> "the user's sister is a lawyer" uses the existing memory to decide
  who "she" is. Label by what the message alone supports: `insufficient`, tag `person` and `pronoun`. (The app sends only
  one message to the extractor, so this is a real product question; counting these separately lets the owner decide.)
* **Confidence, importance, kind, scope, title wording** are not what you judge. Judge the *content* text. If the title says
  something the content does not, judge the content.
* **Language.** Memories may be in Turkish or English regardless of the message language; translation is fine.

## Error-type tags (optional, several allowed, only for insufficient / contradicts)

`person` (attribute moved to the wrong person), `relationship` (wrong relation: brother vs cousin), `negation` (negation lost or
inverted), `plan_vs_fact` (intention stored as a fact), `time_scope` (past or future stored as current), `ownership`
(encounter stored as ownership / commitment), `carryover` (content inherited from the existing memory, see above),
`pronoun` (subject resolved from memory, not from the message), `other` (anything else; add a short note).

## Worked examples

| message | existing memory | proposal | label | tags |
|---|---|---|---|---|
| Sokakta iki yavru kedi buldum, ne yapayım? | - | Kullanıcının iki kedisi var | insufficient | ownership |
| Sokakta iki yavru kedi buldum, ne yapayım? | - | Sokakta iki yavru kedi buldu (event) | supports | |
| Kız kardeşim Berlin'de çalışıyor. | - | Kullanıcı Berlin'de çalışıyor | insufficient | person |
| I'm thinking about moving to Paris next year. | - | User lives in Paris | insufficient | plan_vs_fact |
| I'm thinking about moving to Paris next year. | - | User is considering moving to Paris next year | supports | |
| Geçen yıl Lyon'da yaşıyordum, şimdi İzmir'deyim. | - | Yaşadığı şehir: Lyon | contradicts | time_scope |
| Artık kahve içmiyorum, bıraktım. | Her gün kahve içer | Her gün kahve içer (reinforce) | contradicts | negation |
| Artık kahve içmiyorum, bıraktım. | Her gün kahve içer | Kahveyi bıraktı | supports | |
| Aslında abim değil, kuzenim Almanya'ya taşındı. | Abisi Almanya'ya taşındı | Kuzeni Almanya'ya taşındı | supports | |
| If I get the visa I'll move to Toronto. | - | User is moving to Toronto | insufficient | plan_vs_fact |
| Eşim Ankara'da bir bankada çalışıyor. | - | Eşi Ankara'da bir bankada çalışıyor | supports | |

## Practicalities

* Work alone, do not discuss rows with the other annotator until both sheets are returned.
* Do not look at the `family` or any model name; the sheet hides them on purpose.
* Fill `label`; fill `tags` and `note` only when useful. Leave `note` empty otherwise.
* If a row is unreadable or broken (empty message, truncated text), label `insufficient`, tag `other`, note `broken`.
* Expect about 20-30 seconds per row; 300 rows is roughly two hours. Take breaks; consistency matters more than speed.
