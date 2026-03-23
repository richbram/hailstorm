# Hailstorm — UMLS Integration Guide

> **Status:** This guide is a placeholder for the upcoming UMLS integration phase.
> The procedures below document the planned approach. Implementation scripts will be
> added in a future iteration.

## Overview

The Unified Medical Language System (UMLS) Metathesaurus (2025AB) contains approximately
3.49 million concepts and 17.39 million unique concept names from 190 source vocabularies,
including SNOMED CT, LOINC, RxNorm, ICD-10-CM, MeSH, and CPT.

Hailstorm will support loading the following key UMLS terminologies into Snowstorm:

| Terminology | Format | Load Method | Status |
| :--- | :--- | :--- | :--- |
| SNOMED CT (US Edition) | RF2 Snapshot | Snowstorm native `/imports` API | Planned |
| LOINC | LOINC ZIP | HAPI-FHIR CLI | Planned |
| ICD-10-CM | Tabular XML | HAPI-FHIR CLI | Planned |
| RxNorm | UMLS RRF → Custom CSV | HAPI-FHIR CLI (custom format) | Planned |
| MeSH | UMLS RRF → FHIR CodeSystem | POST /fhir/CodeSystem | Planned |

## Step 1 — Obtain a UMLS License

All UMLS content requires a free license from the National Library of Medicine (NLM).

1. Register for a UTS account at: https://uts.nlm.nih.gov/uts/
2. Accept the UMLS Metathesaurus License Agreement.
3. Note your API key from the UTS profile page.

## Step 2 — Download Source Files

After licensing, download the required files from the UMLS download page:
https://www.nlm.nih.gov/research/umls/licensedcontent/umlsknowledgesources.html

- **SNOMED CT US Edition (RF2):** Available as a separate download under
  "SNOMED CT US Edition" on the NLM SNOMED CT page.
- **LOINC:** Download from https://loinc.org/downloads/
- **ICD-10-CM:** Download from https://www.cms.gov/medicare/coding-billing/icd-10-codes
- **UMLS Full Release (RRF):** Required for RxNorm and MeSH extraction.

## Step 3 — Load SNOMED CT

```bash
export SNOWSTORM_URL=https://hailstorm-<hash>-uc.a.run.app
export GCLOUD_TOKEN=$(gcloud auth print-identity-token)
export RF2_FILE=/path/to/SnomedCT_USEditionRF2_PRODUCTION.zip
bash scripts/load-snomed.sh
```

## Step 4 — Load LOINC (coming soon)

```bash
# Placeholder — implementation pending
hapi-fhir-cli upload-terminology \
    -d Loinc_2.78.zip \
    -v r4 \
    -t "${SNOWSTORM_URL}/fhir" \
    -u http://loinc.org
```

## Step 5 — Load ICD-10-CM (coming soon)

```bash
# Placeholder — implementation pending
hapi-fhir-cli upload-terminology \
    -d icd10cm_tabular_2026.zip \
    -v r4 \
    -t "${SNOWSTORM_URL}/fhir" \
    -u http://hl7.org/fhir/sid/icd-10-cm
```

## Step 6 — Load RxNorm (coming soon)

RxNorm requires transformation from UMLS RRF format to Snowstorm's custom CSV format
before loading. A transformation script will be provided in the next iteration.

## References

- NLM UMLS Homepage: https://www.nlm.nih.gov/research/umls/index.html
- Snowstorm FHIR API docs: https://github.com/IHTSDO/snowstorm/blob/master/docs/using-the-fhir-api.md
- HAPI-FHIR CLI: https://hapifhir.io/hapi-fhir/docs/tools/hapi_fhir_cli.html
