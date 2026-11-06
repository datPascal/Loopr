# PhenoAge test vectors

Provenance for `vectors.json`, read by `PhenoAgeTests`. Fetched 2026-10-24.

## Inputs

| Vector | Input source |
|---|---|
| `pyaging-crp-0.5`, `pyaging-crp-0.21` | pyaging `tests/predict/test_crp_transform.py` at commit `c15cf28347f5b7a984646a16f5f01b95a1e15c20` (2026-10-03, package 0.5.7): the shared row albumin 46.0, creatinine 70.0, glucose 5.0, lymphocyte 30.0, MCV 90.0, RDW 13.0, ALP 70.0, WBC 7.0, age 50.0 with CRP 0.5 and 0.21 mg/dL, both values the test file uses. The file asserts no phenotypic age for them. |
| `mcp-phenoage-clock-readme-us-units` | mcp-phenoage-clock 1.0.1 README sample (github.com/199-biotechnologies/mcp-phenoage-clock): age 45, albumin 4.2 g/dL, creatinine 0.9 mg/dL, glucose 85 mg/dL, CRP 0.5 mg/L, lymphocytes 30 %, MCV 89 fL, RDW 12.5 %, ALP 65 U/L, WBC 6.2. The README states no output. Kept in US units to exercise the unit conversion. |

## Expected values

The two open implementations ship no expected phenotypic age for these rows, so the expected values were computed
outside Loopr, in Python 3 floating point, by following each implementation's own source lines.

- `pyaging`: pyaging 0.5.7 `clocks/notebooks/phenoage.ipynb`. Coefficients to four decimals, intercept -19.9067,
  CRP floored at 0.01 mg/dL then natural log, `gamma = 0.0076927`,
  `141.50225 + (xb + ln(0.00553 * expm1(120 * gamma) / gamma)) / 0.090165`.
- `bioAge`: BioAge (github.com/dayoonkwon/BioAge) `R/phenoage_calc.R`, `orig = TRUE` branch, commit
  `b1f9fc02f086cd4aa74185f2335ab1366082e7fe` (2026-04-02). Coefficients to seven digits, intercept -19.90667,
  `m = 1 - exp(-1.51714 * exp(xb) / 0.007692696)`, `log(-0.0055305 * log(1 - m)) / 0.090165 + 141.50225`.
- `liuCorrection`: the equations printed in Correction, PLoS Med 2019;16(2):e1002760 (PMC6388911), which corrects
  Liu et al., PLoS Med 2018;15(12):e1002718. Intercept -19.907, ALP 0.00188, `141.50`, `-0.00553`, divisor
  `0.09165`. Superseded: Levine 2018 Supplement 1 prints 0.090165. It is here to show how far the superseded
  divisor moves a result (about 1.6 years), not as a target.

Conversions for the US-unit vector use the step 2 factors (creatinine 88.4, glucose 18.016, CRP mg/L / 10), so the
SI values fed to the formulas above are `0.9 * 88.4`, `85 / 18.016` and `0.5 / 10`.

## Transform vectors

`transformVectors` are numbers printed by pyaging, not computed here: log hazards -12, -9 and -6 map to
9.37497303957636, 42.64730709381026 and 75.91964114804416 years (`docs/development/phenoage-gompertz-correction.md`
and `clocks/notebooks/phenoage.ipynb`; `torch.testing.assert_close` with rtol 0 and atol 1e-12; an independent R
4.5.3 evaluation is reported as about 9.37, 42.65 and 75.92).

## Primary source

Levine ME et al. 2018, Aging (Albany NY) 10(4):573-591, Supplement 1, fetched through Europe PMC (PMC5940111),
file `aging-10-101414-s001.pdf`, SHA-256 `5a0b7bf66f1b08079a9ecaf036a26613c61e00f8a8e35e5c13f9bacb61d7cd2c`. It prints
`PhenotypicAge = 141.50225 + ln(-0.00553 * ln(1 - MortalityScore)) / 0.090165` (conversion section and step 4 of the
Gompertz details), `gamma = 0.0076927`, and in Table S1 the coefficients to four decimals and the constant -19.9067.

## What is not here

BioAge has no tests and its vignette prints no PhenoAge output, so no BioAge-published number exists to copy.
