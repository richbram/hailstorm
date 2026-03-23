#!/bin/bash
# =============================================================================
# Hailstorm — UMLS Terminology Downloader
#
# This script automates the downloading of all current UMLS terminology releases
# (SNOMED CT, RxNorm, UMLS Metathesaurus) via the NLM UTS Download API.
#
# Prerequisites:
#   - curl
#   - jq (for JSON parsing)
#   - A valid UTS API Key (export UTS_API_KEY="your_key_here")
#
# Usage:
#   bash scripts/download-umls.sh [output_directory]
# =============================================================================

set -e
set -o pipefail

# --- Configuration ---
API_KEY="${UTS_API_KEY}"
OUT_DIR="${1:-./data/umls}"
BASE_RELEASE_URL="https://uts-ws.nlm.nih.gov/releases"
BASE_DOWNLOAD_URL="https://uts-ws.nlm.nih.gov/download"

# List of release types to download (current versions only)
RELEASE_TYPES=(
    "snomed-ct-us-edition"
    "snomed-ct-international-edition"
    "rxnorm-full-monthly-release"
    "umls-full-release"
)

# --- Helper Functions ---

log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] INFO: $1"
}

error() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2
}

check_prereqs() {
    if [[ -z "${API_KEY}" ]]; then
        error "UTS_API_KEY environment variable is not set."
        error "Get your API key from: https://uts.nlm.nih.gov/uts/profile"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        error "'curl' is required but not installed."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        error "'jq' is required but not installed."
        exit 1
    fi
}

get_current_release_info() {
    local release_type=$1
    local api_url="${BASE_RELEASE_URL}?releaseType=${release_type}&current=true"
    
    local response
    response=$(curl -s "${api_url}")
    
    # Extract fileName and downloadUrl using jq
    local file_name
    local download_url
    
    file_name=$(echo "${response}" | jq -r '.[0].fileName // empty')
    download_url=$(echo "${response}" | jq -r '.[0].downloadUrl // empty')
    
    if [[ -z "${file_name}" || -z "${download_url}" ]]; then
        error "Could not retrieve release info for ${release_type}"
        return 1
    fi
    
    echo "${file_name}|${download_url}"
}

download_file() {
    local release_type=$1
    local file_name=$2
    local source_url=$3
    local target_path="${OUT_DIR}/${file_name}"
    
    if [[ -f "${target_path}" ]]; then
        log "File already exists: ${target_path}. Skipping download."
        return 0
    fi
    
    log "Downloading ${release_type} -> ${file_name}..."
    
    # Construct the authenticated download URL
    local auth_url="${BASE_DOWNLOAD_URL}?url=${source_url}&apiKey=${API_KEY}"
    
    # Download with progress bar and retry logic
    # -L follows redirects
    # -C - resumes broken downloads
    # --retry 3 retries on transient errors
    if curl -L -C - --retry 3 --retry-delay 5 -o "${target_path}" "${auth_url}"; then
        log "Successfully downloaded ${file_name}"
    else
        error "Failed to download ${file_name}"
        rm -f "${target_path}" # Clean up partial file on hard failure
        return 1
    fi
}

# --- Main Execution ---

main() {
    check_prereqs
    
    log "Starting UMLS terminology downloads..."
    log "Output directory: ${OUT_DIR}"
    
    mkdir -p "${OUT_DIR}"
    
    local success_count=0
    local fail_count=0
    
    for rt in "${RELEASE_TYPES[@]}"; do
        log "--- Processing: ${rt} ---"
        
        local release_info
        if ! release_info=$(get_current_release_info "${rt}"); then
            fail_count=$((fail_count + 1))
            continue
        fi
        
        local file_name="${release_info%%|*}"
        local download_url="${release_info##*|}"
        
        log "Found current release: ${file_name}"
        
        if download_file "${rt}" "${file_name}" "${download_url}"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done
    
    log "--- Download Summary ---"
    log "Successfully downloaded: ${success_count}"
    log "Failed downloads: ${fail_count}"
    
    if [[ ${fail_count} -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
