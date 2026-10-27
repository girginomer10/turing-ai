#!/usr/bin/env python3
"""Turn a labeling packet CSV (work/labeling/packet_*.csv) into an Excel workbook with dropdown menus for the annotators.

Sheet 'Rehber' holds the rules (Turkish); sheet 'Etiketle' has one row per proposal with the label column as a strict
dropdown (supports / insufficient / contradicts) and an optional error-type dropdown. Columns that identify the extractor or the
conversation are never written. Filling is checked by a counter on the Rehber sheet.

Run (needs openpyxl):  python -I make_xlsx.py packet_core.csv out.xlsx [--limit 30]
"""
import argparse, csv, os, sys
from openpyxl import Workbook
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.worksheet.datavalidation import DataValidation

LABELS = ["supports", "insufficient", "contradicts"]
TAGS = ["person", "relationship", "negation", "plan_vs_fact", "time_scope", "ownership", "carryover", "pronoun", "other"]

RULES = [
    ("Ne yapıyorsun?", "Her satırda bir kullanıcı mesajı ve uygulamanın bu mesajdan belleğe yazmak istediği bir cümle var. Sorun: bu cümle, MESAJDA yazanla destekleniyor mu?"),
    ("Gerçek doğru mu?", "Önemli değil. Sadece mesajda yazana uyup uymadığına bak. Kullanıcı 'Ay'da yaşıyorum' derse 'Ay'da yaşıyor' supports olur."),
    ("supports", "Mesaj öneriyi düz okumayla söylüyor ya da doğrudan çıkarılıyor. Çeviri, kısaltma, yeniden ifade serbest."),
    ("insufficient", "Mesaj bunu söylemiyor. Öneri bir şey ekliyor veya varsayıyor: plan olgu gibi saklanmış, başka birinin bilgisi kullanıcıya yazılmış, karşılaşma sahiplik olmuş, tarih uydurulmuş."),
    ("contradicts", "Mesaj açıkça tersini söylüyor (olumsuzlama, bırakma, düzeltme, farklı güncel değer)."),
    ("Plan ≠ olgu", "'Paris'e taşınmayı düşünüyorum' -> 'Paris'te yaşıyor' = insufficient. -> 'Taşınmayı düşünüyor' = supports."),
    ("Başkası ≠ kullanıcı", "'Kız kardeşim Berlin'de çalışıyor' -> 'Kullanıcı Berlin'de çalışıyor' = insufficient (yanlış kişi). -> 'Kız kardeşi Berlin'de çalışıyor' = supports."),
    ("Karşılaşma ≠ sahiplik", "'Sokakta iki yavru kedi buldum' -> 'İki kedisi var' = insufficient. -> 'Sokakta iki yavru kedi buldu' = supports."),
    ("Geçmiş ≠ şimdi", "'Geçen yıl Lyon'da yaşıyordum, şimdi İzmir'deyim' -> 'Yaşadığı şehir Lyon' = contradicts."),
    ("Olumsuzlama", "'Artık kahve içmiyorum' -> 'Her gün kahve içer' = contradicts. -> 'Kahveyi bıraktı' = supports."),
    ("Var olan bellek", "Yalnızca bağlam. Eski bir kayıt yeni öneriyi haklı çıkaramaz. Sadece YENİ veya DEĞİŞEN kısmı mesajla karşılaştır. Eski kısım aynen tekrarlanıyorsa onu yeniden yargılama (ama mesajın tersini söylememeli)."),
    ("Zamir", "'O avukat' -> 'Kız kardeşi avukat' gibi, kimin olduğunu eski bellekten çıkarıyorsa: insufficient + etiket 'pronoun'."),
    ("İki iddia bir arada", "Mesaj yalnızca birini destekliyorsa insufficient yaz, hata türü 'other', nota ne olduğunu yaz."),
    ("Yargılama", "Başlık, güven puanı, bellek türü yargılanmaz. Sadece İÇERİK cümlesi."),
    ("Hata türü", "Sadece insufficient/contradicts için, isteğe bağlı. Menüden seç ya da kendin birden fazlasını yaz (virgülle). Emin değilsen boş bırak."),
    ("Emin değilsen", "Atlama. En makul etiketi seç, Not sütununa 'emin değilim' yaz. Bozuk/okunamayan satır: insufficient, tür 'other', not 'broken'."),
    ("Çalışma kuralı", "Diğer etiketleyiciyle satırları konuşma, iki dosya da tamamlanana kadar. Satır başına 20-30 sn; mola ver, tutarlılık hızdan önemli."),
]


def fill_sheet(wb, title, rows):
    et = wb.create_sheet(title)
    last = len(rows) + 1
    order = ["Satır", "Mesaj zamanı", "Kullanıcı mesajı", "Var olan bellek (bağlam)", "Etiket", "Önerilen bellek (içerik)", "Hata türü", "Öneri (işlem)", "Not"]
    et.append(order)
    hdr_fill = PatternFill("solid", fgColor="1B3A5C")
    for c in et[1]:
        c.font = Font(bold=True, color="FFFFFF"); c.fill = hdr_fill; c.alignment = Alignment(wrap_text=True, vertical="center")
    for r in rows:
        et.append([r["row_id"], r["message_time"][:10], r["user_message"], r["existing_memory"], "", r["proposal_content"], "", r["proposal_action"], ""])
    for k, w in {"A": 8, "B": 12, "C": 58, "D": 40, "E": 15, "F": 52, "G": 16, "H": 20, "I": 30}.items(): et.column_dimensions[k].width = w
    for row in et.iter_rows(min_row=2, max_row=last):
        for c in row: c.alignment = Alignment(wrap_text=True, vertical="top")
        row[4].font = Font(bold=True)
    et.freeze_panes = "C2"
    dv = DataValidation(type="list", formula1='"' + ",".join(LABELS) + '"', allow_blank=True, showErrorMessage=True,
                        errorTitle="Etiket", error="supports, insufficient veya contradicts seç.")
    et.add_data_validation(dv); dv.add(f"E2:E{last}")
    dt_ = DataValidation(type="list", formula1='"' + ",".join(TAGS) + '"', allow_blank=True, showErrorMessage=False)
    et.add_data_validation(dt_); dt_.add(f"G2:G{last}")
    for val, color in (("supports", "C6EFCE"), ("insufficient", "FFEB9C"), ("contradicts", "FFC7CE")):
        et.conditional_formatting.add(f"E2:E{last}", FormulaRule(formula=[f'E2="{val}"'], fill=PatternFill("solid", bgColor=color)))
    return last


def build(sheets, out_path, limit, who):
    """sheets: list of (sheet title, csv path)."""
    wb = Workbook()
    ws = wb.active; ws.title = "Rehber"
    ws["A1"] = f"Etiketleme rehberi ({who})"; ws["A1"].font = Font(bold=True, size=14)
    for i, (k, v) in enumerate(RULES, start=3):
        ws.cell(i, 1, k).font = Font(bold=True); c = ws.cell(i, 2, v); c.alignment = Alignment(wrap_text=True, vertical="top")
        ws.cell(i, 1).alignment = Alignment(vertical="top")
    ws.column_dimensions["A"].width = 24; ws.column_dimensions["B"].width = 110
    r = len(RULES) + 5
    ws.cell(r, 1, "İlerleme").font = Font(bold=True)
    total = 0
    for title, path in sheets:
        rows = list(csv.DictReader(open(path, encoding="utf-8")))
        if limit: rows = rows[:limit]
        last = fill_sheet(wb, title, rows); total += len(rows)
        r += 1
        ws.cell(r, 1, title)
        ws.cell(r, 2, f'=COUNTA({title}!E2:E{last}) & " / {len(rows)} etiketlendi"')
    ws.cell(r + 2, 1, "Sıra").font = Font(bold=True)
    ws.cell(r + 2, 2, "Önce ilk sayfayı bitir (iki etiketleyici de aynı satırları yapıyor), sonra ikinci sayfaya geç. Her ~50 satırda dosyayı kaydet.")
    wb.active = 1
    wb.save(out_path)
    print(f"wrote {out_path}: {total} rows in {len(sheets)} sheet(s)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--sheet", action="append", required=True, help="TITLE=path/to/packet.csv (repeat)")
    ap.add_argument("--limit", type=int, default=0); ap.add_argument("--who", default="etiketleyici")
    a = ap.parse_args()
    build([tuple(x.split("=", 1)) for x in a.sheet], a.out, a.limit, a.who)
