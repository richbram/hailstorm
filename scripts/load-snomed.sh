#!/usr/bin/env bash
# =============================================================================
# Hailstorm — SNOMED CT Data Loader
#
# Uploads a SNOMED CT RF2 Snapshot archive to a running Snowstorm instance.
# Run this AFTER the Cloud Run service is deployed and healthy.
#
# Usage:
#   export SNOWSTORM_URL=https://hailstorm-<hash>-uc.a.run.app
#   export RF2_FILE=/path/to/SnomedCT_InternationalRF2_PRODUCTION_20250101T120000Z.zip
#   bash scripts/load-snomed.sh
#
# For Cloud Run (authenticated):
#   export SNOWSTORM_URL=https://hailstorm-<hash>-uc.a.run.app
#   export GCLOUD_TOKEN=$(gcloud auth print-identity-token)
#   bash scripts/load-snomed.sh
#
# UMLS Integration (future):
#   SNOMED CT RF2 files are distributed by the NLM via the UMLS download portal.
#   1. Register at: https://uts.nlm.nih.gov/uts/
#   2. Download: SNOMED CT US Edition (RF2 Snapshot)
#   3. Set RF2_FILE to the downloaded ZIP and run this script.
# =============================================================================

set -euo pipefail

: "${SNOWSTORM_URL:?Please export SNOWSTORM_URL (e.g. https://hailstorm-xxx-uc.a.run.app)}"
: "${RF2_FILE:?Please export RF2_FILE (path to SNOMED CT RF2 Snapshot ZIP)}"

GCLOUD_TOKEN="${GCLOUD_TOKEN:-}"
AUTH_HEADER=""
if [ -n "${GCLOUD_TOKEN}" ]; then
    AUTH_HEADER="-H \"Authorization: Bearer ${GCLOUD_TOKEN}\""
fi

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [load-snomed] $*"; }

# ---------------------------------------------------------------------------
# Step 1 — Create import job
# ---------------------------------------------------------------------------
log "Creating SNOMED CT import job on ${SNOWSTORM_URL}..."

IMPORT_RESPONSE=$(curl -sf \
    -X POST \
    -H "Content-Type: application/json" \
    ${AUTH_HEADER} \
    "${SNOWSTORM_URL}/imports" \
    -d '{
        "branchPath": "MAIN",
        "createCodeSystemVersion": true,
        "type": "SNAPSHOT"
    }')

IMPORT_ID=$(echo "${IMPORT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [ -z "${IMPORT_ID}" ]; then
    log "ERROR: Failed to create import job. Response: ${IMPORT_RESPONSE}"
    exit 1
fi

log "Import job created: ${IMPORT_ID}"

# ---------------------------------------------------------------------------
# Step 2 — Upload RF2 archive
# ---------------------------------------------------------------------------
log "Uploading RF2 archive: ${RF2_FILE} (this may take several minutes)..."

curl -sf \
    -X POST \
    -H "Content-Type: multipart/form-data" \
    ${AUTH_HEADER} \
    -F "file=@${RF2_FILE}" \
    "${SNOWSTORM_URL}/imports/${IMPORT_ID}/archive"

log "Upload complete. Import job ${IMPORT_ID} is now running."

# ---------------------------------------------------------------------------
# Step 3 — Poll import status
# ---------------------------------------------------------------------------
log "Polling import status (this typically takes 30-60 minutes)..."

MAX_WAIT=7200  # 2 hours
ELAPSED=0
POLL_INTERVAL=30

while [ "${ELAPSED}" -lt "${MAX_WAIT}" ]; do
    STATUS_RESPONSE=$(curl -sf \
        -H "Accept: application/json" \
        ${AUTH_HEADER} \
        "${SNOWSTORM_URL}/imports/${IMPORT_ID}" || echo '{"status":"UNKNOWN"}')

    STATUS=$(echo "${STATUS_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")

    log "  Import status: ${STATUS} (elapsed: ${ELAPSED}s)"

    case "${STATUS}" in
        COMPLETED)
            log "Import COMPLETED successfully."
            exit 0
            ;;
        FAILED)
            log "ERROR: Import FAILED. Check Snowstorm logs for details."
            exit 1
            ;;
        *)
            sleep "${POLL_INTERVAL}"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ;;
    esac
done

log "ERROR: Import did not complete within ${MAX_WAIT} seconds."
exit 1
