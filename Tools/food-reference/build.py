"""Builds FoodKit's bundled food table from USDA FoodData Central SR Legacy (April 2018, public domain, CC0).

usage: python3 -I build.py <unzipped FoodData_Central_sr_legacy_food_csv_2018-04 dir> <out.json>

Every value is per 100 g, as USDA publishes it. Salt is sodium x 2.5. Alcohol units are ethanol grams / 10.
Baby foods, branded items, quality-control materials and the American Indian/Alaska Native set are left out.
Portions keep USDA's household measures ("1 cup", "1 large") with their gram weights.
"""
import csv, json, sys
from collections import defaultdict

src, out = sys.argv[1], sys.argv[2]
SKIP_CATEGORIES = {"3", "24", "26", "27"}
NUTRIENTS = {"1008": "energy", "1003": "protein", "1005": "carbs", "1004": "fat", "1079": "fibre",
             "2000": "sugar", "1093": "sodium", "1057": "caffeine", "1018": "alcohol",
             "1092": "potassium", "1258": "saturatedFat"}
# The last three columns (sodium mg, potassium mg, saturated fat g) are stored for a later Food release and not read yet
# (R2-VET-09); FoodKit skips names it does not know.
ORDER = ["energy", "protein", "carbs", "fat", "fibre", "sugar", "salt", "caffeine", "alcoholUnits", "sodium", "potassium", "saturatedFat"]

def rows(name):
    with open(f"{src}/{name}", newline="", encoding="utf-8") as f:
        yield from csv.DictReader(f)

foods = {r["fdc_id"]: r for r in rows("food.csv") if r["food_category_id"] not in SKIP_CATEGORIES}
values = defaultdict(dict)
for r in rows("food_nutrient.csv"):
    key = NUTRIENTS.get(r["nutrient_id"])
    if key and r["fdc_id"] in foods and r["amount"] != "":
        values[r["fdc_id"]][key] = float(r["amount"])
units = {r["id"]: r["name"] for r in rows("measure_unit.csv")}
portions = defaultdict(list)
for r in rows("food_portion.csv"):
    if r["fdc_id"] not in foods or not r["gram_weight"]:
        continue
    unit = units.get(r["measure_unit_id"], "")
    label = " ".join(p for p in [r["amount"].rstrip("0").rstrip(".") if "." in r["amount"] else r["amount"],
                                 "" if unit == "undetermined" else unit, r["modifier"]] if p).strip()
    portions[r["fdc_id"]].append((int(r["seq_num"] or 0), label, round(float(r["gram_weight"]), 1)))

# Household measures that are never what one bare "milk" or "turkey" means.
TOO_BIG_OR_ODD = ("quart", "pint", "gallon", "bunch", "head", "package", "melon", "loaf", "roast", "yield", "box", "jar", "bottle (2")

def default_portion(kept):
    """The household portion a bare count means: "1 banana" is a medium one, "2 eggs" two large ones. Never above
    500 g. Everyday names in common.tsv set theirs by hand."""
    usable = [(i, label, grams) for i, (label, grams) in enumerate(kept)
              if grams <= 500 and not any(word in label for word in TOO_BIG_OR_ODD)]
    for word in ("medium", "large", "slice", "piece", "serving", "fruit", "container", "cup"):
        for i, label, _ in usable:
            if word in label and (word == "cup" or "cup" not in label):
                return i
    for i, label, _ in usable:
        if "tbsp" not in label and "tsp" not in label and "fl oz" not in label:
            return i
    return None

def rounded(v):
    return round(v, 2) if v < 10 else round(v, 1)

table = []
for fid, food in foods.items():
    v = values.get(fid, {})
    if "energy" not in v or "protein" not in v:
        continue
    n = {k: v[k] for k in ("energy", "protein", "carbs", "fat", "fibre", "sugar", "caffeine", "sodium", "potassium", "saturatedFat") if k in v}
    if "sodium" in v: n["salt"] = v["sodium"] * 2.5 / 1000
    if "alcohol" in v: n["alcoholUnits"] = v["alcohol"] / 10
    kept = [[label, grams] for _, label, grams in sorted(portions[fid])][:8]
    name = food["description"].replace(" (Includes foods for USDA's Food Distribution Program)", "")
    row = [int(fid), name, int(food["food_category_id"]),
           [rounded(n[k]) if k in n else None for k in ORDER], kept, default_portion(kept)]
    table.append(row)
table.sort(key=lambda r: r[0])
# Everyday names ("eggs", "chicken", "wine") point at the usual entry, so the first match is the food people mean.
# Each sets its food's default portion: the start of one of USDA's measures, or "label=grams" where USDA has none that
# fits. A default over 500 g or under 1 g fails the build (R2-VET-01: "milk" was a quart).
by_name = {row[1]: row for row in table}
all_portions = {fid: [[label, grams] for _, label, grams in sorted(rows)] for fid, rows in portions.items()}
common = {}
with open(__file__.rsplit("/", 1)[0] + "/common.tsv", encoding="utf-8") as f:
    for line in f:
        if line.startswith("#") or not line.strip():
            continue
        alias, description, spec = line.rstrip("\n").split("\t")
        row = by_name.get(description) or sys.exit(f"common.tsv: no food named {description!r}")
        if "=" in spec:
            label, grams = spec.rsplit("=", 1)
            choice = [label.strip(), float(grams)]
        else:
            choice = next((p for p in all_portions.get(str(row[0]), []) if p[0].startswith(spec)), None)
            if choice is None:
                sys.exit(f"common.tsv: {alias!r} has no USDA measure starting {spec!r}")
        if not 1 <= choice[1] <= 500:
            sys.exit(f"common.tsv: {alias!r} portion {choice} is outside 1 to 500 g")
        if choice not in row[4]:
            row[4].append(choice)
        if row[0] not in common.values():  # the first alias of a food sets its portion
            row[5] = row[4].index(choice)
        common[alias] = row[0]
doc = {"dataset": "USDA FoodData Central, SR Legacy, April 2018", "license": "Public domain (CC0 1.0)",
       "url": "https://fdc.nal.usda.gov/", "basis": "per 100 g", "nutrients": ORDER, "common": common, "foods": table}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
print(len(table), "foods")
