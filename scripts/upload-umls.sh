#!/bin/bash
# =============================================================================
# Hailstorm — UMLS Terminology Uploader
#
# Uploads all downloaded UMLS terminologies into a running Snowstorm instance.
# Each terminology uses the appropriate loading method:
#
#   SNOMED CT (US + International)  → Snowstorm native /imports REST API
#   LOINC                           → HAPI FHIR CLI upload-terminology
#   ICD-10-CM                       → HAPI FHIR CLI upload-terminology
#   RxNorm                          → RRF→CSV transform + HAPI FHIR CLI
#   UMLS Metathesaurus (other vocab)→ RRF→CSV transform + HAPI FHIR CLI
#
# Prerequisites:
#   - curl, jq, python3, unzip
#   - HAPI FHIR CLI (auto-downloaded if not found)
#   - A running Snowstorm instance (SNOWSTORM_URL)
#   - Downloaded UMLS files in UMLS_DATA_DIR (run download-umls.sh first)
#
# Usage:
#   bash scripts/upload-umls.sh [umls_data_dir]
#
# Environment variables:
#   SNOWSTORM_URL      Base URL of Snowstorm (default: http://localhost:8080)
#   UMLS_DATA_DIR      Directory containing downloaded UMLS ZIP files
#   GCLOUD_TOKEN       Optional: Bearer token for Cloud Run IAP authentication
#   SKIP_SNOMED_US     Set to "true" to skip SNOMED CT US Edition upload
#   SKIP_SNOMED_INT    Set to "true" to skip SNOMED CT International upload
#   SKIP_LOINC         Set to "true" to skip LOINC upload
#   SKIP_ICD10CM       Set to "true" to skip ICD-10-CM upload
#   SKIP_RXNORM        Set to "true" to skip RxNorm upload
# =============================================================================

set -eo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SNOWSTORM_URL="${SNOWSTORM_URL:-http://localhost:8080}"
UMLS_DATA_DIR="${1:-./data/umls}"
WORK_DIR="./data/work"
HAPI_CLI_VERSION="8.4.3"
HAPI_CLI_ZIP="hapi-fhir-${HAPI_CLI_VERSION}-cli.zip"
HAPI_CLI_URL="https://github.com/hapifhir/hapi-fhir/releases/download/v${HAPI_CLI_VERSION}/${HAPI_CLI_ZIP}"
HAPI_CLI="./tools/hapi-fhir-cli"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSFORM_SCRIPT="${SCRIPT_DIR}/transform-rrf-to-csv.py"

# Polling configuration for Snowstorm import jobs
POLL_INTERVAL=30
MAX_WAIT=7200  # 2 hours

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()     { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] INFO:    $*"; }
warn()    { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] WARNING: $*" >&2; }
error()   { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR:   $*" >&2; }
section() { echo ""; echo "=========================================================="; echo " $*"; echo "=========================================================="; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_prereqs() {
    local missing=()
    for cmd in curl jq python3 unzip; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        error "Install them and re-run this script."
        exit 1
    fi

    if [[ ! -d "${UMLS_DATA_DIR}" ]]; then
        error "UMLS data directory not found: ${UMLS_DATA_DIR}"
        error "Run scripts/download-umls.sh first."
        exit 1
    fi

    log "Checking Snowstorm health at ${SNOWSTORM_URL}..."
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
        ${GCLOUD_TOKEN:+-H "Authorization: Bearer ${GCLOUD_TOKEN}"} \
        "${SNOWSTORM_URL}/actuator/health" 2>/dev/null || echo "000")

    if [[ "${http_status}" != "200" ]]; then
        error "Snowstorm is not healthy (HTTP ${http_status}). Ensure it is running."
        exit 1
    fi
    log "Snowstorm is healthy."
}

# ---------------------------------------------------------------------------
# HAPI FHIR CLI setup
# ---------------------------------------------------------------------------
ensure_hapi_cli() {
    if [[ -x "${HAPI_CLI}" ]]; then
        log "HAPI FHIR CLI already present: ${HAPI_CLI}"
        return 0
    fi

    log "Downloading HAPI FHIR CLI v${HAPI_CLI_VERSION}..."
    mkdir -p ./tools
    curl -L --retry 3 -o "./tools/${HAPI_CLI_ZIP}" "${HAPI_CLI_URL}"
    unzip -o "./tools/${HAPI_CLI_ZIP}" -d ./tools/
    chmod +x "${HAPI_CLI}"
    log "HAPI FHIR CLI installed at ${HAPI_CLI}"
}

# ---------------------------------------------------------------------------
# Auth header helper (supports Cloud Run IAP tokens)
# ---------------------------------------------------------------------------
auth_header() {
    if [[ -n "${GCLOUD_TOKEN}" ]]; then
        echo "-H \"Authorization: Bearer ${GCLOUD_TOKEN}\""
    fi
}

# ---------------------------------------------------------------------------
# Find the most recent file matching a glob pattern in UMLS_DATA_DIR
# ---------------------------------------------------------------------------
find_latest_file() {
    local pattern="$1"
    local found
    found=$(find "${UMLS_DATA_DIR}" -maxdepth 1 -name "${pattern}" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | awk '{print $2}')
    echo "${found}"
}

# ---------------------------------------------------------------------------
# SNOMED CT upload via Snowstorm native /imports API
# ---------------------------------------------------------------------------
upload_snomed() {
    local label="$1"
    local rf2_file="$2"
    local branch="${3:-MAIN}"

    section "Uploading ${label}"

    if [[ -z "${rf2_file}" || ! -f "${rf2_file}" ]]; then
        warn "No RF2 file found for ${label}. Skipping."
        return 0
    fi

    log "RF2 file: ${rf2_file}"
    log "Target branch: ${branch}"

    # Step 1: Create import job
    log "Creating Snowstorm import job..."
    local import_response
    import_response=$(curl -s -X POST \
        ${GCLOUD_TOKEN:+-H "Authorization: Bearer ${GCLOUD_TOKEN}"} \
        -H "Content-Type: application/json" \
        -d "{\"branchPath\":\"${branch}\",\"createCodeSystemVersion\":true,\"type\":\"SNAPSHOT\"}" \
        "${SNOWSTORM_URL}/imports")

    local import_id
    import_id=$(echo "${import_response}" | jq -r '.id // empty')

    if [[ -z "${import_id}" ]]; then
        error "Failed to create import job. Response: ${import_response}"
        return 1
    fi
    log "Import job created: ${import_id}"

    # Step 2: Upload RF2 archive
    log "Uploading RF2 archive (this may take several minutes)..."
    local upload_status
    upload_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        ${GCLOUD_TOKEN:+-H "Authorization: Bearer ${GCLOUD_TOKEN}"} \
        -H "Content-Type: multipart/form-data" \
        -F "file=@${rf2_file}" \
        "${SNOWSTORM_URL}/imports/${import_id}/archive")

    if [[ "${upload_status}" != "200" && "${upload_status}" != "201" ]]; then
        error "RF2 upload failed (HTTP ${upload_status})."
        return 1
    fi
    log "RF2 archive uploaded successfully."

    # Step 3: Poll for completion
    log "Polling import status (max wait: ${MAX_WAIT}s)..."
    local elapsed=0
    while [[ ${elapsed} -lt ${MAX_WAIT} ]]; do
        local status_response
        status_response=$(curl -s \
            ${GCLOUD_TOKEN:+-H "Authorization: Bearer ${GCLOUD_TOKEN}"} \
            "${SNOWSTORM_URL}/imports/${import_id}")
        local status
        status=$(echo "${status_response}" | jq -r '.status // "UNKNOWN"')

        log "  Status: ${status} (elapsed: ${elapsed}s)"

        case "${status}" in
            COMPLETED)
                log "${label} import COMPLETED successfully."
                return 0
                ;;
            FAILED)
                error "${label} import FAILED. Check Snowstorm logs."
                return 1
                ;;
            *)
                sleep "${POLL_INTERVAL}"
                elapsed=$((elapsed + POLL_INTERVAL))
                ;;
        esac
    done

    error "Import timed out after ${MAX_WAIT}s."
    return 1
}

# ---------------------------------------------------------------------------
# Generic HAPI FHIR CLI upload
# ---------------------------------------------------------------------------
upload_via_hapi_cli() {
    local label="$1"
    local data_file="$2"
    local system_url="$3"

    section "Uploading ${label}"

    if [[ -z "${data_file}" || ! -f "${data_file}" ]]; then
        warn "No file found for ${label}. Skipping."
        return 0
    fi

    log "Data file: ${data_file}"
    log "System URL: ${system_url}"

    local fhir_url="${SNOWSTORM_URL}/fhir"

    # Build auth args for HAPI CLI (it does not support Bearer tokens natively;
    # for Cloud Run, use a local proxy or set SNOWSTORM_URL to an IAP-exempt endpoint)
    log "Running HAPI FHIR CLI upload-terminology..."
    if "${HAPI_CLI}" upload-terminology \
        -d "${data_file}" \
        -v r4 \
        -t "${fhir_url}" \
        -u "${system_url}"; then
        log "${label} upload COMPLETED successfully."
    else
        error "${label} upload FAILED."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# RxNorm: transform RRF → Snowstorm custom CSV, then upload via HAPI CLI
# ---------------------------------------------------------------------------
upload_rxnorm() {
    local rxnorm_zip
    rxnorm_zip=$(find_latest_file "RxNorm_full_*.zip")

    section "Uploading RxNorm"

    if [[ -z "${rxnorm_zip}" ]]; then
        warn "No RxNorm ZIP found in ${UMLS_DATA_DIR}. Skipping."
        return 0
    fi

    log "RxNorm source: ${rxnorm_zip}"

    # Unzip RxNorm to work directory
    local rxnorm_work="${WORK_DIR}/rxnorm"
    mkdir -p "${rxnorm_work}"

    log "Extracting RxNorm archive..."
    unzip -o "${rxnorm_zip}" -d "${rxnorm_work}" > /dev/null

    # Find RXNCONSO.RRF and RXNREL.RRF
    local rxnconso rxnrel
    rxnconso=$(find "${rxnorm_work}" -name "RXNCONSO.RRF" | head -1)
    rxnrel=$(find "${rxnorm_work}" -name "RXNREL.RRF" | head -1)

    if [[ -z "${rxnconso}" ]]; then
        error "RXNCONSO.RRF not found in RxNorm archive."
        return 1
    fi

    log "Found RXNCONSO.RRF: ${rxnconso}"
    log "Found RXNREL.RRF:   ${rxnrel:-not found, hierarchy will be empty}"

    # Transform RRF to Snowstorm custom format
    local custom_dir="${WORK_DIR}/rxnorm_custom"
    mkdir -p "${custom_dir}"

    log "Transforming RxNorm RRF to Snowstorm custom code system format..."
    python3 "${TRANSFORM_SCRIPT}" \
        --conso "${rxnconso}" \
        ${rxnrel:+--rel "${rxnrel}"} \
        --output-dir "${custom_dir}" \
        --system-url "http://www.nlm.nih.gov/research/umls/rxnorm" \
        --system-name "RxNorm" \
        --system-description "NLM RxNorm — normalized names for clinical drugs"

    # Zip the custom code system package
    local custom_zip="${WORK_DIR}/rxnorm_custom.zip"
    log "Creating custom code system ZIP: ${custom_zip}"
    (cd "${custom_dir}" && zip -r "${custom_zip}" .)

    upload_via_hapi_cli "RxNorm" "${custom_zip}" "http://www.nlm.nih.gov/research/umls/rxnorm"
}

# ---------------------------------------------------------------------------
# UMLS Metathesaurus: extract selected vocabularies and upload
# ---------------------------------------------------------------------------
upload_umls_metathesaurus() {
    local umls_zip
    umls_zip=$(find_latest_file "umls-*-metathesaurus-full.zip")
    if [[ -z "${umls_zip}" ]]; then
        umls_zip=$(find_latest_file "umls-*-full.zip")
    fi

    section "Uploading UMLS Metathesaurus Vocabularies"

    if [[ -z "${umls_zip}" ]]; then
        warn "No UMLS Metathesaurus ZIP found in ${UMLS_DATA_DIR}. Skipping."
        return 0
    fi

    log "UMLS source: ${umls_zip}"

    # Vocabularies to extract from MRCONSO.RRF (SAB column values)
    # These are vocabularies not available as standalone downloads
    declare -A VOCAB_MAP=(
        ["MSH"]="http://terminology.hl7.org/CodeSystem/MSH|MeSH|Medical Subject Headings"
        ["CPT"]="http://www.ama-assn.org/go/cpt|CPT|Current Procedural Terminology"
        ["HCPCS"]="http://terminology.hl7.org/CodeSystem/HCPCS|HCPCS|Healthcare Common Procedure Coding System"
        ["NCI"]="http://ncicb.nci.nih.gov/xml/owl/EVS/Thesaurus.owl|NCI|NCI Thesaurus"
    )

    local umls_work="${WORK_DIR}/umls"
    mkdir -p "${umls_work}"

    log "Extracting UMLS Metathesaurus archive (large file — this may take a while)..."
    unzip -o "${umls_zip}" "*/MRCONSO.RRF" "*/MRREL.RRF" -d "${umls_work}" > /dev/null 2>&1 || true

    local mrconso mrrel
    mrconso=$(find "${umls_work}" -name "MRCONSO.RRF" | head -1)
    mrrel=$(find "${umls_work}" -name "MRREL.RRF" | head -1)

    if [[ -z "${mrconso}" ]]; then
        error "MRCONSO.RRF not found in UMLS archive."
        return 1
    fi

    log "Found MRCONSO.RRF: ${mrconso}"

    local vocab_success=0
    local vocab_fail=0

    for sab in "${!VOCAB_MAP[@]}"; do
        IFS="|" read -r sys_url sys_name sys_desc <<< "${VOCAB_MAP[$sab]}"

        log "--- Processing vocabulary: ${sab} (${sys_name}) ---"

        local custom_dir="${WORK_DIR}/umls_${sab}"
        local custom_zip="${WORK_DIR}/umls_${sab}.zip"
        mkdir -p "${custom_dir}"

        log "Transforming ${sab} from MRCONSO.RRF..."
        if python3 "${TRANSFORM_SCRIPT}" \
            --conso "${mrconso}" \
            ${mrrel:+--rel "${mrrel}"} \
            --sab "${sab}" \
            --output-dir "${custom_dir}" \
            --system-url "${sys_url}" \
            --system-name "${sys_name}" \
            --system-description "${sys_desc}"; then

            log "Creating ZIP: ${custom_zip}"
            (cd "${custom_dir}" && zip -r "${custom_zip}" .)

            if upload_via_hapi_cli "${sys_name}" "${custom_zip}" "${sys_url}"; then
                vocab_success=$((vocab_success + 1))
            else
                vocab_fail=$((vocab_fail + 1))
            fi
        else
            warn "Transform failed for ${sab}. Skipping."
            vocab_fail=$((vocab_fail + 1))
        fi
    done

    log "Metathesaurus vocabulary summary: ${vocab_success} succeeded, ${vocab_fail} failed."
    [[ ${vocab_fail} -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    section "Hailstorm — UMLS Terminology Uploader"
    log "Snowstorm URL:    ${SNOWSTORM_URL}"
    log "UMLS data dir:    ${UMLS_DATA_DIR}"
    log "Work directory:   ${WORK_DIR}"

    check_prereqs
    ensure_hapi_cli
    mkdir -p "${WORK_DIR}"

    local overall_success=0
    local overall_fail=0

    # ------------------------------------------------------------------
    # 1. SNOMED CT US Edition
    # ------------------------------------------------------------------
    if [[ "${SKIP_SNOMED_US}" != "true" ]]; then
        snomed_us=$(find_latest_file "SnomedCT_ManagedServiceUS_*.zip")
        if upload_snomed "SNOMED CT US Edition" "${snomed_us}" "MAIN"; then
            overall_success=$((overall_success + 1))
        else
            overall_fail=$((overall_fail + 1))
        fi
    else
        log "Skipping SNOMED CT US Edition (SKIP_SNOMED_US=true)"
    fi

    # ------------------------------------------------------------------
    # 2. SNOMED CT International Edition
    # ------------------------------------------------------------------
    if [[ "${SKIP_SNOMED_INT}" != "true" ]]; then
        snomed_int=$(find_latest_file "SnomedCT_InternationalRF2_*.zip")
        if upload_snomed "SNOMED CT International Edition" "${snomed_int}" "MAIN"; then
            overall_success=$((overall_success + 1))
        else
            overall_fail=$((overall_fail + 1))
        fi
    else
        log "Skipping SNOMED CT International Edition (SKIP_SNOMED_INT=true)"
    fi

    # ------------------------------------------------------------------
    # 3. LOINC
    # ------------------------------------------------------------------
    if [[ "${SKIP_LOINC}" != "true" ]]; then
        loinc_file=$(find_latest_file "Loinc_*.zip")
        if upload_via_hapi_cli "LOINC" "${loinc_file}" "http://loinc.org"; then
            overall_success=$((overall_success + 1))
        else
            overall_fail=$((overall_fail + 1))
        fi
    else
        log "Skipping LOINC (SKIP_LOINC=true)"
    fi

    # ------------------------------------------------------------------
    # 4. ICD-10-CM
    # ------------------------------------------------------------------
    if [[ "${SKIP_ICD10CM}" != "true" ]]; then
        icd_file=$(find_latest_file "icd10cm_tabular_*.zip")
        if upload_via_hapi_cli "ICD-10-CM" "${icd_file}" "http://hl7.org/fhir/sid/icd-10-cm"; then
            overall_success=$((overall_success + 1))
        else
            overall_fail=$((overall_fail + 1))
        fi
    else
        log "Skipping ICD-10-CM (SKIP_ICD10CM=true)"
    fi

    # ------------------------------------------------------------------
    # 5. RxNorm (requires RRF→CSV transformation)
    # ------------------------------------------------------------------
    if [[ "${SKIP_RXNORM}" != "true" ]]; then
        if upload_rxnorm; then
            overall_success=$((overall_success + 1))
        else
            overall_fail=$((overall_fail + 1))
        fi
    else
        log "Skipping RxNorm (SKIP_RXNORM=true)"
    fi

    # ------------------------------------------------------------------
    # 6. UMLS Metathesaurus vocabularies (MeSH, CPT, HCPCS, NCI)
    # ------------------------------------------------------------------
    if [[ "${SKIP_UMLS_META}" != "true" ]]; then
        if upload_umls_metathesaurus; then
            overall_success=$((overall_success + 1))
        else
            overall_fail=$((overall_fail + 1))
        fi
    else
        log "Skipping UMLS Metathesaurus (SKIP_UMLS_META=true)"
    fi

    # ------------------------------------------------------------------
    # Final summary
    # ------------------------------------------------------------------
    section "Upload Summary"
    log "Succeeded: ${overall_success}"
    log "Failed:    ${overall_fail}"

    if [[ ${overall_fail} -gt 0 ]]; then
        error "One or more uploads failed. Review the log above."
        exit 1
    fi

    log "All terminologies uploaded successfully."
}

main "$@"
