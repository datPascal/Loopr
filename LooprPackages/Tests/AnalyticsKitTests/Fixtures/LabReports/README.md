# Lab report text fixtures

Every file here is synthetic. The names, dates, numbers, lab names and layouts were written for these tests. None of it
comes from a real person's report, and no real lab's template was copied. The values are plausible so that rows look
like rows in typical reports; they say nothing about anyone.

Each file is a list of recognised lines in the shape the parser takes: `text`, the box as `x`, `y`, `w`, `h`
(normalised to the page, origin at the bottom left, the way Vision reports a bounding box) and `c`, the recognition
confidence. The boxes were placed by a small script, one row per 0.0245 of page height, one cell per column.

| File | What it covers |
|---|---|
| `en-report.json` | An English report, one test per row. Header with a collection date and time ("September 12, 2026 08:15"), a receipt date, a birth date that must not be read as the collection date, "Fasting: yes", and the lab name. All 28 catalog markers once, plus a vitamin B12 row and a testosterone row in a unit the parser does not know. Ranges as "3.5 - 5.2", "< 90", "> 60", a flag "H", a flag "*", trailing zeros ("41.0", "5.0", "1.90"), a unit written "x10E3/uL" and one written "mL/min/1.73 m2". |
| `de-report.json` | A German report, one test per row. Report title, lab name, birth date, "Probenentnahme" with date and time, "Eingangsdatum", "Befunddatum" (a report date), "nüchtern". All 28 catalog markers once with German names (Kreatinin, Glukose nüchtern, CRP (hochsensitiv), Alkalische Phosphatase, Leukozyten, Triglyzeride, 25-OH-Vitamin D, GOT (AST), GPT (ALT), Gamma-GT, Harnsäure and the rest), decimal commas, ranges as "0,60-1,20", "(70 - 99)", "Ref.: 35 bis 52", "< 3,0", "> 40", the qualitative reference "negativ", units written "µg/l", "Tsd./µl", "µU/ml" and "ml/min/1,73m²". |
| `noisy-report.json` | A German report with the faults a camera adds. Two columns on one page. "O" read for "0" in "O,9", "9O", "5,O" and "12O". A name wrapped over two lines ("Alkalische" above "Phosphatase 72 U/l"). A name alone above its value ("Lipoprotein(a)" above "38 nmol/l < 75"). A missing unit, a unit the marker is not reported in (HDL in g/l), a unit the parser does not know (pg/ml), a result printed "<0,3" (read as a limit with its sign), a garbled value ("9?2"), a cell read at 0.45 confidence, an unknown test, and a "Seite 1 von 2" line that is not a result. |

Expected counts, asserted in `LabReportParserTests`:

| File | Values read | Need a look | Rows skipped |
|---|---|---|---|
| `en-report.json` | 30 | 1 | 0 |
| `de-report.json` | 29 | 0 | 0 |
| `noisy-report.json` | 17 | 8 | 1 |
