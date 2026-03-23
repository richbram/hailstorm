# Hailstorm — Deployment Guide

This document provides a detailed, step-by-step guide for deploying Hailstorm (Snowstorm on Google Cloud Run).

## Prerequisites

Before starting, ensure you have the following installed and configured:

- [gcloud CLI](https://cloud.google.com/sdk/docs/install) (authenticated with `gcloud auth login`)
- Docker Desktop (for local builds and testing)
- A GCP project with billing enabled

## 1. Local Development

Local development uses Docker Compose to run Elasticsearch and Snowstorm as separate containers, mirroring the production architecture.

```bash
# Start the full stack
docker compose -f docker/docker-compose.yml up -d

# Tail logs
docker compose -f docker/docker-compose.yml logs -f

# Stop
docker compose -f docker/docker-compose.yml down
```

The SNOMED CT Browser UI will be available at `http://localhost:80` and the FHIR API at `http://localhost:8080/fhir`.

## 2. Building the Production Docker Image

The production image bundles both Elasticsearch and Snowstorm into a single container. This is suitable for Cloud Run where persistent sidecar containers are not supported.

```bash
# Build locally
docker build \
  --build-arg SNOWSTORM_VERSION=10.10.1 \
  --build-arg ES_VERSION=8.11.1 \
  -t hailstorm:local .

# Test the image locally
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e SNOWSTORM_READONLY=false \
  hailstorm:local
```

## 3. GCP Infrastructure Setup

Run the bootstrap script once to provision all required GCP resources:

```bash
export PROJECT_ID=your-gcp-project-id
export REGION=us-central1
bash scripts/setup-gcp.sh
```

This script creates:
- An Artifact Registry Docker repository (`hailstorm`)
- A dedicated Cloud Run service account (`hailstorm-sa`)
- Required IAM bindings for Cloud Build and Cloud Run

## 4. Cloud Build CI/CD

Cloud Build is the preferred CI/CD tool. It connects directly to the GitHub repository via a mirrored Cloud Source Repository.

### Connecting the Repository

1. Navigate to **Cloud Build → Triggers** in the GCP console.
2. Click **Connect Repository**.
3. Select **GitHub** and authorise the OAuth flow.
4. Select `richbram/hailstorm` and confirm.

### Creating the Trigger

Create a trigger with the following configuration:

| Field | Value |
| :--- | :--- |
| Name | `hailstorm-develop-deploy` |
| Event | Push to branch |
| Branch | `^develop$` |
| Config type | Cloud Build configuration file |
| Config file location | `deploy/cloudbuild/cloudbuild.yaml` |

Add the following substitution variables:

| Variable | Value |
| :--- | :--- |
| `_REGION` | `us-central1` |
| `_SERVICE_NAME` | `hailstorm-dev` |
| `_IMAGE_NAME` | `us-central1-docker.pkg.dev/<PROJECT_ID>/hailstorm/snowstorm` |

### Triggering a Build

Push any commit to the `develop` branch:

```bash
git push origin develop
```

Cloud Build will automatically build, push, and deploy the image.

## 5. Cloud Run Configuration

The Cloud Run service is defined in `deploy/cloudrun/service.yaml`. Key settings:

- **Memory:** 8 GiB minimum (4 GiB for Elasticsearch + 2 GiB for Snowstorm + 2 GiB OS)
- **CPU:** 4 vCPUs (always allocated to prevent Elasticsearch from being throttled)
- **Min instances:** 0 for dev (set to 1 for production to avoid cold starts)
- **Timeout:** 3600 seconds (required for long-running SNOMED CT imports)

### Updating the Service Manually

```bash
gcloud run services replace deploy/cloudrun/service.yaml \
  --region=us-central1
```

## 6. Health Checks

Cloud Run uses the following probes:

| Probe | Path | Notes |
| :--- | :--- | :--- |
| Startup | `/actuator/health` | Allows up to 10 minutes for Snowstorm to initialise |
| Liveness | `/actuator/health/liveness` | Restarts container if Snowstorm becomes unresponsive |
| Readiness | `/actuator/health/readiness` | Stops traffic if Elasticsearch is not healthy |

## 7. Post-Deployment: Loading SNOMED CT

After the service is deployed, load SNOMED CT data using the provided script:

```bash
export SNOWSTORM_URL=$(gcloud run services describe hailstorm-dev \
    --region=us-central1 --format='value(status.url)')
export GCLOUD_TOKEN=$(gcloud auth print-identity-token)
export RF2_FILE=/path/to/SnomedCT_InternationalRF2_PRODUCTION.zip
bash scripts/load-snomed.sh
```

Once loading is complete, set `SNOWSTORM_READONLY=true` in the Cloud Run environment variables to lock down the write API.

## 8. Environment Variables Reference

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PORT` | `8080` | HTTP port (injected by Cloud Run) |
| `SNOWSTORM_READONLY` | `false` | Set to `true` after data load |
| `SNOWSTORM_JVM_OPTS` | `-Xms2g -Xmx4g ...` | JVM heap for Snowstorm |
| `SNOWSTORM_EXTRA_ARGS` | `` | Additional Spring Boot arguments |
| `ES_PATH_DATA` | `/data/elasticsearch` | Elasticsearch data directory |
