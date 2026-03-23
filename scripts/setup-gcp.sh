#!/usr/bin/env bash
# =============================================================================
# Hailstorm — GCP Infrastructure Bootstrap Script
#
# Run this ONCE to provision all required GCP resources before the first
# Cloud Build / Cloud Run deployment.
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (gcloud auth login)
#   - Billing enabled on the target project
#
# Usage:
#   export PROJECT_ID=your-gcp-project-id
#   export REGION=us-central1
#   bash scripts/setup-gcp.sh
# =============================================================================

set -euo pipefail

: "${PROJECT_ID:?Please export PROJECT_ID before running this script}"
: "${REGION:=us-central1}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "=== Hailstorm GCP Setup ==="
log "Project : ${PROJECT_ID}"
log "Region  : ${REGION}"
echo ""

# ---------------------------------------------------------------------------
# 1. Set project
# ---------------------------------------------------------------------------
gcloud config set project "${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 2. Enable required APIs
# ---------------------------------------------------------------------------
log "Enabling required GCP APIs..."
gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    cloudresourcemanager.googleapis.com \
    iam.googleapis.com

# ---------------------------------------------------------------------------
# 3. Create Artifact Registry repository
# ---------------------------------------------------------------------------
log "Creating Artifact Registry repository..."
gcloud artifacts repositories create hailstorm \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Hailstorm (Snowstorm) Docker images" \
    2>/dev/null || log "  (repository already exists — skipping)"

# ---------------------------------------------------------------------------
# 4. Create a dedicated service account for Cloud Run
# ---------------------------------------------------------------------------
SA_NAME="hailstorm-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

log "Creating service account: ${SA_EMAIL}..."
gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Hailstorm Cloud Run Service Account" \
    2>/dev/null || log "  (service account already exists — skipping)"

# Grant minimum required roles
log "Granting IAM roles to service account..."
for ROLE in \
    roles/logging.logWriter \
    roles/monitoring.metricWriter \
    roles/cloudtrace.agent \
    roles/secretmanager.secretAccessor; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="${ROLE}" \
        --quiet
done

# ---------------------------------------------------------------------------
# 5. Grant Cloud Build service account permission to deploy to Cloud Run
# ---------------------------------------------------------------------------
CB_SA="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')@cloudbuild.gserviceaccount.com"
log "Granting Cloud Build SA (${CB_SA}) Cloud Run admin role..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CB_SA}" \
    --role="roles/run.admin" \
    --quiet

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CB_SA}" \
    --role="roles/iam.serviceAccountUser" \
    --quiet

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CB_SA}" \
    --role="roles/artifactregistry.writer" \
    --quiet

# ---------------------------------------------------------------------------
# 6. Create Cloud Build trigger
#    NOTE: This connects to the GitHub repo via Cloud Source Repositories mirror.
#    You must first mirror the repo in the Cloud Build console:
#    Console → Cloud Build → Triggers → Connect Repository
# ---------------------------------------------------------------------------
log ""
log "=== MANUAL STEP REQUIRED ==="
log "Connect your GitHub repo (richbram/hailstorm) to Cloud Build:"
log "  1. Open: https://console.cloud.google.com/cloud-build/triggers?project=${PROJECT_ID}"
log "  2. Click 'Connect Repository' and follow the GitHub OAuth flow."
log "  3. Create a trigger with:"
log "       Branch filter : ^develop\$"
log "       Config file   : deploy/cloudbuild/cloudbuild.yaml"
log "       Substitutions :"
log "         _REGION       = ${REGION}"
log "         _SERVICE_NAME = hailstorm-dev"
log "         _IMAGE_NAME   = ${REGION}-docker.pkg.dev/${PROJECT_ID}/hailstorm/snowstorm"
log ""

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
log "=== Setup complete ==="
log "Artifact Registry : ${REGION}-docker.pkg.dev/${PROJECT_ID}/hailstorm/snowstorm"
log "Service Account   : ${SA_EMAIL}"
log "Next step         : Connect the GitHub repo in Cloud Build console (see above)."
