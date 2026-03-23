# Hailstorm

**Hailstorm** is a production-ready deployment scaffold for [Snowstorm](https://github.com/IHTSDO/snowstorm) — the open-source SNOMED CT / FHIR terminology server — targeting **Google Cloud Run**.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Google Cloud Run (hailstorm-dev / hailstorm-prod)          │
│                                                             │
│  ┌──────────────────────┐   ┌──────────────────────────┐   │
│  │  Snowstorm           │   │  Elasticsearch 8.x       │   │
│  │  (FHIR + SNOMED API) │◄──│  (single-node, local)    │   │
│  │  Port 8080           │   │  Port 9200               │   │
│  └──────────────────────┘   └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
         ▲
         │  HTTPS
         │
┌────────┴──────────┐
│  Cloud Load       │
│  Balancer / IAP   │
└───────────────────┘
```

> **Note:** For production at scale, Elasticsearch should be externalised to a managed cluster (Elastic Cloud, GCP Marketplace). The current setup bundles both services in a single container for simplicity and cost-efficiency during evaluation.

---

## Repository Structure

```
hailstorm/
├── Dockerfile                        # Multi-stage build: Snowstorm + Elasticsearch
├── .dockerignore
├── .gitignore
│
├── config/
│   └── snowstorm.properties          # Spring Boot / Snowstorm configuration
│
├── deploy/
│   ├── cloudbuild/
│   │   └── cloudbuild.yaml           # Cloud Build CI/CD pipeline
│   └── cloudrun/
│       └── service.yaml              # Cloud Run service definition
│
├── docker/
│   └── docker-compose.yml            # Local development environment
│
├── scripts/
│   ├── entrypoint.sh                 # Container startup (starts ES, then Snowstorm)
│   ├── setup-gcp.sh                  # One-time GCP infrastructure bootstrap
│   └── load-snomed.sh                # SNOMED CT RF2 data loader
│
└── docs/
    ├── deployment.md                 # Step-by-step deployment guide
    └── umls-integration.md           # UMLS loading guide (coming next)
```

---

## Quick Start — Local Development

**Prerequisites:** Docker Desktop with at least 8 GB RAM allocated.

```bash
# 1. Clone the repository
git clone https://github.com/richbram/hailstorm.git
cd hailstorm
git checkout develop

# 2. Start the stack
docker compose -f docker/docker-compose.yml up -d

# 3. Wait for Snowstorm to become healthy (~2-3 minutes)
docker compose -f docker/docker-compose.yml logs -f snowstorm

# 4. Verify the FHIR API is responding
curl http://localhost:8080/fhir/metadata | python3 -m json.tool | head -20

# 5. Load SNOMED CT (requires RF2 file — see docs/umls-integration.md)
export SNOWSTORM_URL=http://localhost:8080
export RF2_FILE=/path/to/SnomedCT_InternationalRF2_PRODUCTION.zip
bash scripts/load-snomed.sh
```

---

## Deployment to Google Cloud Run

### Step 1 — Bootstrap GCP infrastructure (once)

```bash
export PROJECT_ID=your-gcp-project-id
export REGION=us-central1
bash scripts/setup-gcp.sh
```

### Step 2 — Connect GitHub repo to Cloud Build

1. Open [Cloud Build Triggers](https://console.cloud.google.com/cloud-build/triggers) in the GCP console.
2. Click **Connect Repository** and authorise GitHub access for `richbram/hailstorm`.
3. Create a trigger with the following settings:

| Setting | Value |
| :--- | :--- |
| **Branch filter** | `^develop$` |
| **Config file** | `deploy/cloudbuild/cloudbuild.yaml` |
| `_REGION` | `us-central1` |
| `_SERVICE_NAME` | `hailstorm-dev` |
| `_IMAGE_NAME` | `us-central1-docker.pkg.dev/<PROJECT_ID>/hailstorm/snowstorm` |

### Step 3 — Push to trigger a build

```bash
git push origin develop
```

Cloud Build will build the Docker image, push it to Artifact Registry, and deploy it to Cloud Run automatically.

### Step 4 — Load SNOMED CT data

```bash
export SNOWSTORM_URL=$(gcloud run services describe hailstorm-dev \
    --region=us-central1 --format='value(status.url)')
export GCLOUD_TOKEN=$(gcloud auth print-identity-token)
export RF2_FILE=/path/to/SnomedCT_InternationalRF2_PRODUCTION.zip
bash scripts/load-snomed.sh
```

---

## API Endpoints

| Endpoint | Description |
| :--- | :--- |
| `GET /fhir/metadata` | FHIR CapabilityStatement |
| `GET /fhir/CodeSystem/$lookup?system=http://snomed.info/sct&code=<code>` | SNOMED CT concept lookup |
| `GET /fhir/ValueSet/$expand?url=<ecl-url>` | ValueSet expansion (supports ECL) |
| `GET /fhir/CodeSystem/$validate-code` | Code validation |
| `GET /swagger-ui.html` | Snowstorm native API (Swagger UI) |
| `GET /actuator/health` | Health check |

---

## UMLS Integration

Loading standard UMLS terminologies (SNOMED CT, LOINC, ICD-10, RxNorm) is covered in [docs/umls-integration.md](docs/umls-integration.md).

---

## Hardware Requirements

| Environment | RAM | CPU | Storage |
| :--- | :--- | :--- | :--- |
| Local dev | 8 GB | 4 cores | 50 GB SSD |
| Cloud Run (dev) | 8 GiB | 4 vCPU | Ephemeral (data in GCS) |
| Cloud Run (prod) | 16 GiB | 8 vCPU | External Elasticsearch |

---

## Contributing

All development work should be done on the `develop` branch. Pull requests to `main` are reviewed before production deployment.
