# =============================================================================
# Hailstorm — Snowstorm Terminology Server
# Dockerfile for Google Cloud Run deployment
#
# Architecture:
#   This image bundles Snowstorm (the SNOMED CT / FHIR terminology server) and
#   a single-node Elasticsearch instance into one container. This is appropriate
#   for Cloud Run where sidecar containers share the same execution environment.
#
#   For production at scale, Elasticsearch should be externalised to a managed
#   service (e.g. Elastic Cloud, GCP Marketplace Elasticsearch) and only the
#   Snowstorm JAR should run in this container.
#
# Build args:
#   SNOWSTORM_VERSION   — Snowstorm release tag (default: 10.10.1)
#   ES_VERSION          — Elasticsearch version (default: 8.11.1)
# =============================================================================

ARG SNOWSTORM_VERSION=10.10.1
ARG ES_VERSION=8.11.1

# ---------------------------------------------------------------------------
# Stage 1 — Download Snowstorm JAR
# ---------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy AS snowstorm-download

ARG SNOWSTORM_VERSION

RUN apt-get update -qq && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
    "https://github.com/IHTSDO/snowstorm/releases/download/${SNOWSTORM_VERSION}/snowstorm-${SNOWSTORM_VERSION}.jar" \
    -o /snowstorm.jar

# ---------------------------------------------------------------------------
# Stage 2 — Runtime image (Snowstorm + Elasticsearch)
# ---------------------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy AS runtime

ARG ES_VERSION

# Install Elasticsearch
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        curl ca-certificates wget gnupg \
    && wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
       > /etc/apt/sources.list.d/elastic-8.x.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends "elasticsearch=${ES_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Elasticsearch tuning for single-node, low-memory Cloud Run environment
RUN echo "xpack.security.enabled: false"              >> /etc/elasticsearch/elasticsearch.yml \
    && echo "discovery.type: single-node"             >> /etc/elasticsearch/elasticsearch.yml \
    && echo "node.name: snowstorm"                    >> /etc/elasticsearch/elasticsearch.yml \
    && echo "cluster.name: snowstorm-cluster"         >> /etc/elasticsearch/elasticsearch.yml \
    && echo "network.host: 127.0.0.1"                 >> /etc/elasticsearch/elasticsearch.yml \
    && echo "http.port: 9200"                         >> /etc/elasticsearch/elasticsearch.yml \
    && echo "-Xms2g"                                  >> /etc/elasticsearch/jvm.options.d/heap.options \
    && echo "-Xmx2g"                                  >> /etc/elasticsearch/jvm.options.d/heap.options

# Kernel virtual memory setting (required by Elasticsearch)
# NOTE: On Cloud Run this must also be set at the host level via a startup script
# or by using a privileged init container. The sysctl below is a best-effort
# attempt that may be ignored in unprivileged containers.
RUN sysctl -w vm.max_map_count=262144 2>/dev/null || true

# Copy Snowstorm JAR from download stage
COPY --from=snowstorm-download /snowstorm.jar /app/snowstorm.jar

# Copy startup script and configuration
COPY scripts/entrypoint.sh /app/entrypoint.sh
COPY config/snowstorm.properties /app/snowstorm.properties

RUN chmod +x /app/entrypoint.sh

# Create data directories
RUN mkdir -p /data/elasticsearch /data/snowstorm \
    && chown -R elasticsearch:elasticsearch /data/elasticsearch

# Cloud Run listens on PORT env var (default 8080)
ENV PORT=8080
EXPOSE 8080

# Snowstorm JVM settings — tuned for Cloud Run (8 GB+ instance recommended)
ENV SNOWSTORM_JVM_OPTS="-Xms2g -Xmx4g --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED"

ENTRYPOINT ["/app/entrypoint.sh"]
