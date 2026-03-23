# Hailstorm — UMLS Integration Guide

**Date:** March 20, 2026  
**Subject:** Loading UMLS Standard Terminologies into Snowstorm

This guide provides step-by-step instructions for downloading standard medical terminologies via the Unified Medical Language System (UMLS) and loading them into a running Snowstorm instance.

---

## 1. Prerequisites and Licensing

The UMLS Metathesaurus contains over 190 source vocabularies. Accessing this data requires a free license from the U.S. National Library of Medicine (NLM).

### 1.1 Obtain a UMLS License
1. Register for a UMLS Terminology Services (UTS) account at [uts.nlm.nih.gov](https://uts.nlm.nih.gov/uts/signup-login) [1].
2. Accept the UMLS Metathesaurus License Agreement.
3. Navigate to your **UTS Profile** to generate and retrieve your **API Key** [2].

### 1.2 Required Tools
For non-SNOMED terminologies, you must install the **HAPI FHIR CLI**:
```bash
# Download the latest HAPI FHIR CLI (v8.4.3 or later)
wget https://github.com/hapifhir/hapi-fhir/releases/download/v8.4.3/hapi-fhir-8.4.3-cli.zip
unzip hapi-fhir-8.4.3-cli.zip
chmod +x hapi-fhir-cli
```

Set your Snowstorm environment variable:
```bash
export SNOWSTORM_URL="https://hailstorm-dev-uc.a.run.app"
# Or http://localhost:8080 for local development
```

---

## 2. Loading SNOMED CT (US Edition)

Snowstorm is natively built for SNOMED CT. You do not use the HAPI CLI for this; instead, use Snowstorm's native `/imports` API.

### 2.1 Download
You can automate the download of all UMLS terminologies (including SNOMED CT, RxNorm, and the UMLS Metathesaurus) using the provided script:

```bash
export UTS_API_KEY="your-uts-api-key"
bash scripts/download-umls.sh ./data/umls
```
This script queries the UTS Release API for the latest versions and downloads them with resume and retry logic.

Alternatively, to download manually:
```bash
export API_KEY="your-uts-api-key"
curl "https://uts-ws.nlm.nih.gov/download?url=https://download.nlm.nih.gov/mlb/utsauth/USExt/SnomedCT_USEditionRF2_PRODUCTION_20250901T120000Z.zip&apiKey=${API_KEY}" -o SnomedCT_US_Edition.zip
```

### 2.2 Load
Use the provided Hailstorm script:
```bash
export RF2_FILE=SnomedCT_US_Edition.zip
bash scripts/load-snomed.sh
```
*Note: This process takes 30–60 minutes depending on your database resources.*

---

## 3. Loading LOINC

Snowstorm supports LOINC natively via the HAPI FHIR CLI [3].

### 3.1 Download
Download the latest LOINC release directly from Regenstrief (requires a free LOINC account):
```bash
# Example using LOINC Download API (requires auth token)
curl -X GET 'https://loinc.regenstrief.org/api/v1/Loinc/Download?version=2.81' \
  -H "Authorization: Bearer YOUR_LOINC_TOKEN" \
  -o Loinc_2.81.zip
```

### 3.2 Load
Upload the raw ZIP file using the HAPI CLI:
```bash
./hapi-fhir-cli upload-terminology \
    -d Loinc_2.81.zip \
    -v r4 \
    -t "${SNOWSTORM_URL}/fhir" \
    -u http://loinc.org
```

---

## 4. Loading ICD-10-CM

Snowstorm supports the US version of ICD-10 (ICD-10-CM) in tabular XML format [3].

### 4.1 Download
Download the latest ICD-10-CM tabular files from the CMS website:
```bash
wget https://www.cms.gov/files/zip/2026-code-tables-tabular-and-index.zip
unzip 2026-code-tables-tabular-and-index.zip
# Locate the tabular XML file (e.g., icd10cm_tabular_2026.xml) and zip it
zip icd10cm_tabular_2026.zip icd10cm_tabular_2026.xml
```

### 4.2 Load
Upload the tabular ZIP file using the HAPI CLI:
```bash
./hapi-fhir-cli upload-terminology \
    -d icd10cm_tabular_2026.zip \
    -v r4 \
    -t "${SNOWSTORM_URL}/fhir" \
    -u http://hl7.org/fhir/sid/icd-10-cm
```

---

## 5. Loading RxNorm

Unlike LOINC and ICD-10, Snowstorm **does not natively parse RxNorm RRF files**. RxNorm must be transformed into Snowstorm's **Custom Code System format** before loading [3].

### 5.1 Download
If you ran the `download-umls.sh` script in Step 2.1, the latest RxNorm release is already downloaded to your `./data/umls` directory. 

Otherwise, download it manually via the UTS API:
```bash
curl "https://uts-ws.nlm.nih.gov/download?url=https://download.nlm.nih.gov/umls/kss/rxnorm/RxNorm_full_current.zip&apiKey=${API_KEY}" -o RxNorm_full.zip
```
Unzip the file to access the `rrf/` directory.

### 5.2 Transform to Custom Format
Snowstorm requires a ZIP file containing four specific files [4]:
1. `codesystem.json` (FHIR CodeSystem resource definition)
2. `concepts.csv` (CODE, DISPLAY)
3. `hierarchy.csv` (PARENT, CHILD)
4. `properties.csv` (CODE, KEY, VALUE, TYPE)

You must write a script to extract this data from the RxNorm `rrf/RXNCONSO.RRF` and `rrf/RXNREL.RRF` files. 
* A basic extraction maps `RXCUI` to `CODE` and `STR` to `DISPLAY`.
* Hierarchies are extracted from `RXNREL.RRF` where `REL` = `isa`.

### 5.3 Load
Once transformed and zipped into `rxnorm_custom.zip`:
```bash
./hapi-fhir-cli upload-terminology \
    -d rxnorm_custom.zip \
    -v r4 \
    -t "${SNOWSTORM_URL}/fhir" \
    -u http://www.nlm.nih.gov/research/umls/rxnorm
```

---

## 6. Loading Other UMLS Vocabularies (e.g., MeSH)

For other vocabularies like MeSH, you have two options:

**Option A: HL7 Terminology Package (Recommended)**
Snowstorm supports loading FHIR NPM packages directly [3].
```bash
# Download the HL7 terminology package
npm --registry https://packages.simplifier.net pack hl7.terminology.r4@6.1.0

# Load MeSH from the package into Snowstorm
curl --form file=@hl7.terminology.r4-6.1.0.tgz \
  --form resourceUrls="http://terminology.hl7.org/CodeSystem/mesh" \
  "${SNOWSTORM_URL}/fhir-admin/load-package"
```

**Option B: Custom Code System**
If the vocabulary is not in the HL7 package, extract it from the UMLS Metathesaurus `MRCONSO.RRF` file, convert it to the Snowstorm Custom Code System CSV format (as described in the RxNorm section), and load it via the HAPI CLI.

---
### References
[1] NLM, "How to License and Access the UMLS," *NIH*, 2026. [Online]. Available: https://www.nlm.nih.gov/databases/umls.html
[2] NLM, "Automating UMLS Terminology Services Downloads," *NIH*, 2026. [Online]. Available: https://documentation.uts.nlm.nih.gov/automating-downloads.html
[3] SNOMED International, "Snowstorm FHIR API Documentation," *GitHub*, 2026. [Online]. Available: https://github.com/IHTSDO/snowstorm/blob/master/docs/using-the-fhir-api.md
[4] SNOMED International, "Custom Code System Format," *GitHub*, 2026. [Online]. Available: https://github.com/IHTSDO/snowstorm/tree/master/docs/fhir-resources/custom_code_system
