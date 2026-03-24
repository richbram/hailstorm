#!/usr/bin/env python3
"""
transform-rrf-to-csv.py — Hailstorm UMLS RRF to Snowstorm Custom Code System Transformer

Converts NLM RRF (Rich Release Format) files from RxNorm or the UMLS Metathesaurus
into the four-file custom code system format that Snowstorm's HAPI FHIR CLI
upload-terminology command accepts.

Output format (per Snowstorm docs):
  codesystem.json  — FHIR CodeSystem resource stub (content: not-present)
  concepts.csv     — CODE,DISPLAY
  hierarchy.csv    — PARENT,CHILD
  properties.csv   — CODE,KEY,VALUE,TYPE

RxNorm source files:
  RXNCONSO.RRF     — Concept names (pipe-delimited, 18 columns)
  RXNREL.RRF       — Relationships (pipe-delimited, 16 columns)

UMLS Metathesaurus source files:
  MRCONSO.RRF      — Concept names (pipe-delimited, 19 columns)
  MRREL.RRF        — Relationships (pipe-delimited, 16 columns)

Usage:
  python3 transform-rrf-to-csv.py \\
      --conso RXNCONSO.RRF \\
      --rel RXNREL.RRF \\
      --output-dir ./rxnorm_custom \\
      --system-url http://www.nlm.nih.gov/research/umls/rxnorm \\
      --system-name RxNorm \\
      --system-description "NLM RxNorm normalized drug names"

  # For a specific vocabulary from MRCONSO.RRF (e.g., MeSH):
  python3 transform-rrf-to-csv.py \\
      --conso MRCONSO.RRF \\
      --rel MRREL.RRF \\
      --sab MSH \\
      --output-dir ./mesh_custom \\
      --system-url http://terminology.hl7.org/CodeSystem/MSH \\
      --system-name MeSH \\
      --system-description "Medical Subject Headings"
"""

import argparse
import csv
import json
import logging
import os
import sys
from collections import defaultdict
from datetime import date

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# RRF column indices
# ---------------------------------------------------------------------------

# RXNCONSO.RRF columns (18 fields, 0-indexed):
#  0:RXCUI  1:LAT  2:TS  3:LUI  4:STT  5:SUI  6:ISPREF  7:RXAUI
#  8:SAUI   9:SCUI  10:SDUI  11:SAB  12:TTY  13:CODE  14:STR  15:SRL  16:SUPPRESS  17:CVF
RXNCONSO_RXCUI   = 0
RXNCONSO_LAT     = 1
RXNCONSO_ISPREF  = 6
RXNCONSO_SAB     = 11
RXNCONSO_TTY     = 12
RXNCONSO_CODE    = 13
RXNCONSO_STR     = 14
RXNCONSO_SUPPRESS = 16

# RXNREL.RRF columns (16 fields, 0-indexed):
#  0:RXCUI1  1:RXAUI1  2:STYPE1  3:REL  4:RXCUI2  5:RXAUI2  6:STYPE2
#  7:RELA  8:RUI  9:SRUI  10:SAB  11:SL  12:DIR  13:RG  14:SUPPRESS  15:CVF
RXNREL_RXCUI1   = 0
RXNREL_REL      = 3
RXNREL_RXCUI2   = 4
RXNREL_RELA     = 7
RXNREL_SAB      = 10
RXNREL_SUPPRESS = 14

# MRCONSO.RRF columns (19 fields, 0-indexed):
#  0:CUI  1:LAT  2:TS  3:LUI  4:STT  5:SUI  6:ISPREF  7:AUI
#  8:SAUI  9:SCUI  10:SDUI  11:SAB  12:TTY  13:CODE  14:STR  15:SRL  16:SUPPRESS  17:CVF  18:(empty)
MRCONSO_CUI      = 0
MRCONSO_LAT      = 1
MRCONSO_ISPREF   = 6
MRCONSO_SAB      = 11
MRCONSO_TTY      = 12
MRCONSO_CODE     = 13
MRCONSO_STR      = 14
MRCONSO_SUPPRESS = 16

# MRREL.RRF columns (16 fields, 0-indexed):
#  0:CUI1  1:AUI1  2:STYPE1  3:REL  4:CUI2  5:AUI2  6:STYPE2
#  7:RELA  8:RUI  9:SRUI  10:SAB  11:SL  12:DIR  13:RG  14:SUPPRESS  15:CVF
MRREL_CUI1    = 0
MRREL_REL     = 3
MRREL_CUI2    = 4
MRREL_RELA    = 7
MRREL_SAB     = 10
MRREL_SUPPRESS = 14


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def parse_rxnconso(conso_path: str) -> dict[str, str]:
    """
    Parse RXNCONSO.RRF and return a dict of {RXCUI: preferred_display}.
    Preference order: English (ENG), preferred term (ISPREF=Y), TTY=IN (ingredient).
    """
    log.info("Parsing RXNCONSO.RRF: %s", conso_path)
    concepts: dict[str, str] = {}
    # Track preference: (is_eng, is_pref, is_in_tty) → higher is better
    scores: dict[str, int] = {}

    with open(conso_path, encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            if line_no % 500_000 == 0:
                log.info("  Processed %d lines...", line_no)
            parts = line.rstrip("\n").split("|")
            if len(parts) < 17:
                continue
            if parts[RXNCONSO_SUPPRESS] in ("O", "E"):
                continue  # Skip obsolete/erroneous

            rxcui   = parts[RXNCONSO_RXCUI]
            lat     = parts[RXNCONSO_LAT]
            ispref  = parts[RXNCONSO_ISPREF]
            tty     = parts[RXNCONSO_TTY]
            display = parts[RXNCONSO_STR].strip()

            if not rxcui or not display:
                continue

            score = (
                (1 if lat == "ENG" else 0) * 4 +
                (1 if ispref == "Y" else 0) * 2 +
                (1 if tty in ("IN", "PIN", "MIN", "SCD", "SCDC") else 0)
            )

            if rxcui not in scores or score > scores[rxcui]:
                concepts[rxcui] = display
                scores[rxcui] = score

    log.info("  Parsed %d unique RxNorm concepts.", len(concepts))
    return concepts


def parse_mrconso(conso_path: str, sab: str) -> dict[str, str]:
    """
    Parse MRCONSO.RRF for a specific source abbreviation (SAB) and return
    a dict of {CODE: preferred_display}.
    """
    log.info("Parsing MRCONSO.RRF for SAB=%s: %s", sab, conso_path)
    concepts: dict[str, str] = {}
    scores: dict[str, int] = {}

    with open(conso_path, encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            if line_no % 1_000_000 == 0:
                log.info("  Processed %d lines...", line_no)
            parts = line.rstrip("\n").split("|")
            if len(parts) < 17:
                continue
            if parts[MRCONSO_SAB] != sab:
                continue
            if parts[MRCONSO_SUPPRESS] in ("O", "E"):
                continue

            code    = parts[MRCONSO_CODE].strip()
            lat     = parts[MRCONSO_LAT]
            ispref  = parts[MRCONSO_ISPREF]
            display = parts[MRCONSO_STR].strip()

            if not code or not display:
                continue

            score = (
                (1 if lat == "ENG" else 0) * 2 +
                (1 if ispref == "Y" else 0)
            )

            if code not in scores or score > scores[code]:
                concepts[code] = display
                scores[code] = score

    log.info("  Parsed %d unique concepts for SAB=%s.", len(concepts), sab)
    return concepts


def parse_rxnrel(rel_path: str, valid_codes: set[str]) -> list[tuple[str, str]]:
    """
    Parse RXNREL.RRF and return a list of (parent_rxcui, child_rxcui) tuples
    representing isa / ingredient_of relationships.
    """
    log.info("Parsing RXNREL.RRF: %s", rel_path)
    hierarchy: list[tuple[str, str]] = []
    isa_rels = {"isa", "ingredient_of", "has_ingredient", "tradename_of"}

    with open(rel_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("|")
            if len(parts) < 15:
                continue
            if parts[RXNREL_SUPPRESS] in ("O", "E"):
                continue

            rela    = parts[RXNREL_RELA].lower()
            rxcui1  = parts[RXNREL_RXCUI1]
            rxcui2  = parts[RXNREL_RXCUI2]

            if rela not in isa_rels:
                continue
            if rxcui1 not in valid_codes or rxcui2 not in valid_codes:
                continue

            # Normalise to (parent, child):
            # isa → rxcui2 is parent of rxcui1
            # ingredient_of → rxcui2 is parent of rxcui1
            if rela in ("isa", "ingredient_of"):
                hierarchy.append((rxcui2, rxcui1))
            elif rela == "tradename_of":
                hierarchy.append((rxcui2, rxcui1))

    log.info("  Parsed %d hierarchy relationships.", len(hierarchy))
    return hierarchy


def parse_mrrel(rel_path: str, sab: str, valid_codes: set[str]) -> list[tuple[str, str]]:
    """
    Parse MRREL.RRF for a specific SAB and return (parent_code, child_code) tuples.
    """
    log.info("Parsing MRREL.RRF for SAB=%s: %s", sab, rel_path)
    hierarchy: list[tuple[str, str]] = []

    with open(rel_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("|")
            if len(parts) < 15:
                continue
            if parts[MRREL_SAB] != sab:
                continue
            if parts[MRREL_SUPPRESS] in ("O", "E"):
                continue

            rela  = parts[MRREL_RELA].lower()
            cui1  = parts[MRREL_CUI1]
            cui2  = parts[MRREL_CUI2]

            if rela not in ("isa", "is_a", "broader_than", "has_broader"):
                continue
            if cui1 not in valid_codes or cui2 not in valid_codes:
                continue

            # isa → cui2 is parent of cui1
            hierarchy.append((cui2, cui1))

    log.info("  Parsed %d hierarchy relationships for SAB=%s.", len(hierarchy), sab)
    return hierarchy


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def write_codesystem_json(output_dir: str, system_url: str, system_name: str,
                           system_description: str) -> None:
    cs = {
        "resourceType": "CodeSystem",
        "url": system_url,
        "name": system_name.replace(" ", ""),
        "title": system_name,
        "description": system_description,
        "status": "active",
        "hierarchyMeaning": "is-a",
        "publisher": "National Library of Medicine (NLM)",
        "date": date.today().isoformat(),
        "content": "not-present",
    }
    path = os.path.join(output_dir, "codesystem.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cs, fh, indent=2)
    log.info("Written: %s", path)


def write_concepts_csv(output_dir: str, concepts: dict[str, str]) -> None:
    path = os.path.join(output_dir, "concepts.csv")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["CODE", "DISPLAY"])
        for code, display in concepts.items():
            # Escape display strings that contain commas or quotes
            writer.writerow([code, display])
    log.info("Written: %s (%d concepts)", path, len(concepts))


def write_hierarchy_csv(output_dir: str, hierarchy: list[tuple[str, str]]) -> None:
    path = os.path.join(output_dir, "hierarchy.csv")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["PARENT", "CHILD"])
        for parent, child in hierarchy:
            writer.writerow([parent, child])
    log.info("Written: %s (%d relationships)", path, len(hierarchy))


def write_properties_csv(output_dir: str, properties: list[tuple[str, str, str, str]]) -> None:
    """
    properties: list of (CODE, KEY, VALUE, TYPE)
    For RxNorm/UMLS we write an empty properties file (no extra properties needed).
    """
    path = os.path.join(output_dir, "properties.csv")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["CODE", "KEY", "VALUE", "TYPE"])
        for row in properties:
            writer.writerow(row)
    log.info("Written: %s (%d properties)", path, len(properties))


# ---------------------------------------------------------------------------
# Main transform logic
# ---------------------------------------------------------------------------

def transform(args: argparse.Namespace) -> None:
    os.makedirs(args.output_dir, exist_ok=True)

    is_rxnorm = (args.sab is None)

    # Step 1: Parse concepts
    if is_rxnorm:
        concepts = parse_rxnconso(args.conso)
    else:
        concepts = parse_mrconso(args.conso, args.sab)

    if not concepts:
        log.error("No concepts found. Check --conso path and --sab value.")
        sys.exit(1)

    valid_codes = set(concepts.keys())

    # Step 2: Parse hierarchy (optional)
    hierarchy: list[tuple[str, str]] = []
    if args.rel and os.path.isfile(args.rel):
        if is_rxnorm:
            hierarchy = parse_rxnrel(args.rel, valid_codes)
        else:
            hierarchy = parse_mrrel(args.rel, args.sab, valid_codes)
    else:
        log.warning("No --rel file provided or file not found. Hierarchy will be empty.")

    # Step 3: Write output files
    log.info("Writing Snowstorm custom code system files to: %s", args.output_dir)
    write_codesystem_json(args.output_dir, args.system_url, args.system_name,
                          args.system_description)
    write_concepts_csv(args.output_dir, concepts)
    write_hierarchy_csv(args.output_dir, hierarchy)
    write_properties_csv(args.output_dir, [])  # No extra properties for RxNorm/UMLS

    log.info("Transformation complete. Output in: %s", args.output_dir)
    log.info("Next step: zip the output directory and run:")
    log.info("  hapi-fhir-cli upload-terminology -d <zip> -v r4 -t <snowstorm>/fhir -u %s",
             args.system_url)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transform NLM RRF files to Snowstorm custom code system format.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--conso", required=True,
        help="Path to RXNCONSO.RRF (RxNorm) or MRCONSO.RRF (UMLS Metathesaurus)",
    )
    parser.add_argument(
        "--rel", default=None,
        help="Path to RXNREL.RRF or MRREL.RRF (optional; used for hierarchy)",
    )
    parser.add_argument(
        "--sab", default=None,
        help="Source abbreviation to extract from MRCONSO.RRF (e.g. MSH, CPT). "
             "Omit for RxNorm (RXNCONSO.RRF).",
    )
    parser.add_argument(
        "--output-dir", required=True,
        help="Directory to write the four output files into",
    )
    parser.add_argument(
        "--system-url", required=True,
        help="FHIR CodeSystem URL (e.g. http://www.nlm.nih.gov/research/umls/rxnorm)",
    )
    parser.add_argument(
        "--system-name", required=True,
        help="Human-readable code system name (e.g. RxNorm)",
    )
    parser.add_argument(
        "--system-description", default="",
        help="Short description of the code system",
    )
    args = parser.parse_args()
    transform(args)


if __name__ == "__main__":
    main()
