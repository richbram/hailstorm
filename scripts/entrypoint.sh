#!/usr/bin/env bash
# =============================================================================
# Hailstorm — Container Entrypoint
#
# Starts Elasticsearch first, waits for it to become healthy, then starts
# Snowstorm. Both processes are managed so that if either exits the container
# exits as well (Cloud Run will restart it).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [entrypoint] $*"; }

wait_for_elasticsearch() {
    local max_attempts=60
    local attempt=0
    log "Waiting for Elasticsearch to become healthy..."
    until curl -sf "http://127.0.0.1:9200/_cluster/health?wait_for_status=yellow&timeout=5s" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_attempts" ]; then
            log "ERROR: Elasticsearch did not become healthy after ${max_attempts} attempts. Exiting."
            exit 1
        fi
        log "  Elasticsearch not ready yet (attempt ${attempt}/${max_attempts}). Retrying in 5s..."
        sleep 5
    done
    log "Elasticsearch is healthy."
}

# ---------------------------------------------------------------------------
# Apply vm.max_map_count (best-effort; may fail in unprivileged containers)
# ---------------------------------------------------------------------------
sysctl -w vm.max_map_count=262144 2>/dev/null \
    || log "WARN: Could not set vm.max_map_count (unprivileged container). Elasticsearch may fail to start."

# ---------------------------------------------------------------------------
# Start Elasticsearch as the elasticsearch OS user
# ---------------------------------------------------------------------------
log "Starting Elasticsearch..."
ES_PATH_DATA="${ES_PATH_DATA:-/data/elasticsearch}"
export ES_PATH_DATA

su -s /bin/bash elasticsearch -c \
    "/usr/share/elasticsearch/bin/elasticsearch \
        -E path.data=${ES_PATH_DATA} \
        -E path.logs=/var/log/elasticsearch" &
ES_PID=$!
log "Elasticsearch started (PID: ${ES_PID})"

wait_for_elasticsearch

# ---------------------------------------------------------------------------
# Start Snowstorm
# ---------------------------------------------------------------------------
log "Starting Snowstorm..."

# Cloud Run injects PORT; Snowstorm uses server.port
SNOWSTORM_PORT="${PORT:-8080}"

# Allow callers to inject extra Spring properties via SNOWSTORM_EXTRA_ARGS
SNOWSTORM_EXTRA_ARGS="${SNOWSTORM_EXTRA_ARGS:-}"

# Read-only mode can be toggled via env var (useful after initial data load)
READONLY_MODE="${SNOWSTORM_READONLY:-false}"

# shellcheck disable=SC2086
java ${SNOWSTORM_JVM_OPTS:--Xms2g -Xmx4g --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED} \
    -jar /app/snowstorm.jar \
    --spring.config.additional-location=/app/snowstorm.properties \
    --elasticsearch.urls=http://127.0.0.1:9200 \
    --server.port="${SNOWSTORM_PORT}" \
    --snowstorm.rest-api.readonly="${READONLY_MODE}" \
    ${SNOWSTORM_EXTRA_ARGS} &
SNOWSTORM_PID=$!
log "Snowstorm started (PID: ${SNOWSTORM_PID})"

# ---------------------------------------------------------------------------
# Wait for either process to exit; exit with its code
# ---------------------------------------------------------------------------
wait -n "${ES_PID}" "${SNOWSTORM_PID}"
EXIT_CODE=$?
log "A child process exited with code ${EXIT_CODE}. Shutting down container."
kill "${ES_PID}" "${SNOWSTORM_PID}" 2>/dev/null || true
exit "${EXIT_CODE}"
