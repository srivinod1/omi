#!/usr/bin/env bash
# One-time GCP setup for self-hosting the Omi backend.
#
# Creates: a new GCP project, required API enablement, Firestore (native
# mode), GCS buckets, an Artifact Registry Docker repo, a runtime service
# account for Cloud Run, a deploy service account + Workload Identity
# Federation for GitHub Actions (no long-lived JSON key leaves your machine),
# and empty Secret Manager entries ready for your real API keys.
#
# Run this from a terminal where you've already done:
#   gcloud auth login
#   gcloud auth application-default login
#
# Usage:
#   PROJECT_ID=omi-selfhost-6969 BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX \
#     ./selfhost/gcp-bootstrap.sh
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID, e.g. PROJECT_ID=omi-selfhost-6969}"
: "${BILLING_ACCOUNT_ID:?Set BILLING_ACCOUNT_ID. List yours with: gcloud billing accounts list}"
REGION="${REGION:-us-central1}"
GITHUB_REPO="${GITHUB_REPO:-srivinod1/omi}"
GITHUB_BRANCH="${GITHUB_BRANCH:-custom}"
PROJECT_NAME="${PROJECT_NAME:-Omi Self-Host}"

RUNTIME_SA_ID="omi-backend-run"
DEPLOY_SA_ID="omi-github-deployer"
WIF_POOL_ID="github-pool"
WIF_PROVIDER_ID="github-provider"
AR_REPO="omi"

RUNTIME_SA_EMAIL="${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
DEPLOY_SA_EMAIL="${DEPLOY_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Project: $PROJECT_ID  Region: $REGION  Repo: $GITHUB_REPO@$GITHUB_BRANCH ==="
read -r -p "This will create real, potentially billable GCP resources. Continue? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "Aborted."; exit 1; }

# Retries a flaky command a few times with backoff. New projects/service
# accounts take a few seconds to propagate through IAM, and Cloud Resource
# Manager / Artifact Registry calls right after project creation routinely
# 403/404 until that catches up.
retry() {
  local attempt=1 max=6 delay=5
  until "$@"; do
    if (( attempt >= max )); then
      echo "  Giving up after $attempt attempts: $*" >&2
      return 1
    fi
    echo "  Retrying in ${delay}s (attempt $((attempt+1))/$max)..." >&2
    sleep "$delay"
    attempt=$((attempt+1))
    delay=$((delay+5))
  done
}

if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  echo "==> Project $PROJECT_ID already exists, reusing it."
else
  echo "==> Creating project..."
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME"
fi

echo "==> Linking billing..."
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"

gcloud config set project "$PROJECT_ID"

echo "==> Enabling APIs (this can take a minute)..."
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  firestore.googleapis.com \
  firebase.googleapis.com \
  cloudresourcemanager.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com

echo "==> Creating Firestore database (native mode)..."
gcloud firestore databases create --location="$REGION" --type=firestore-native || \
  echo "  (already exists? continuing)"

echo "==> Creating Artifact Registry repo..."
if ! gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" >/dev/null 2>&1; then
  retry gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker --location="$REGION" \
    --description="Omi self-host images"
fi

echo "==> Creating GCS buckets..."
for suffix in speech-profiles backups plugin-logos frame-requests frame-requests-temp; do
  bucket="gs://${PROJECT_ID}-${suffix}"
  gsutil mb -l "$REGION" "$bucket" 2>/dev/null || echo "  $bucket already exists? continuing"
done

echo "==> Creating runtime service account ($RUNTIME_SA_EMAIL)..."
if ! gcloud iam service-accounts describe "$RUNTIME_SA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$RUNTIME_SA_ID" \
    --display-name="Omi backend/pusher Cloud Run runtime"
  retry gcloud iam service-accounts describe "$RUNTIME_SA_EMAIL" >/dev/null
fi

for role in roles/datastore.user roles/secretmanager.secretAccessor roles/logging.logWriter roles/monitoring.metricWriter; do
  retry gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA_EMAIL}" --role="$role" --condition=None >/dev/null
done

echo "==> Granting bucket access to runtime SA..."
for suffix in speech-profiles backups plugin-logos frame-requests frame-requests-temp; do
  retry gsutil iam ch "serviceAccount:${RUNTIME_SA_EMAIL}:roles/storage.objectAdmin" "gs://${PROJECT_ID}-${suffix}"
done

echo "==> Creating GitHub Actions deploy service account ($DEPLOY_SA_EMAIL)..."
if ! gcloud iam service-accounts describe "$DEPLOY_SA_EMAIL" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$DEPLOY_SA_ID" \
    --display-name="GitHub Actions deployer for Omi self-host"
  retry gcloud iam service-accounts describe "$DEPLOY_SA_EMAIL" >/dev/null
fi

for role in roles/run.admin roles/artifactregistry.writer; do
  retry gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOY_SA_EMAIL}" --role="$role" --condition=None >/dev/null
done
# Let the deployer act as the runtime SA when deploying Cloud Run revisions.
retry gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA_EMAIL" \
  --member="serviceAccount:${DEPLOY_SA_EMAIL}" --role="roles/iam.serviceAccountUser"

echo "==> Setting up Workload Identity Federation for GitHub Actions..."
gcloud iam workload-identity-pools create "$WIF_POOL_ID" \
  --location="global" --display-name="GitHub Actions pool" || echo "  (already exists? continuing)"

gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER_ID" \
  --location="global" --workload-identity-pool="$WIF_POOL_ID" \
  --display-name="GitHub OIDC" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com" || echo "  (already exists? continuing)"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
WIF_POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}"

retry gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WIF_POOL_RESOURCE}/attribute.repository/${GITHUB_REPO}"

WIF_PROVIDER_RESOURCE="${WIF_POOL_RESOURCE}/providers/${WIF_PROVIDER_ID}"

echo "==> Creating empty Secret Manager entries..."
for secret in OPENAI_API_KEY DEEPGRAM_API_KEY PINECONE_API_KEY REDIS_DB_PASSWORD ENCRYPTION_SECRET ADMIN_KEY ELEVENLABS_API_KEY; do
  gcloud secrets create "$secret" --replication-policy=automatic 2>/dev/null || echo "  $secret already exists? continuing"
done

cat <<EOF

================================================================================
Bootstrap done. Save this — you'll need it for GitHub Actions and deploys:

  PROJECT_ID           = $PROJECT_ID
  REGION                = $REGION
  ARTIFACT_REGISTRY_REPO = ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}
  RUNTIME_SERVICE_ACCOUNT = $RUNTIME_SA_EMAIL
  DEPLOY_SERVICE_ACCOUNT  = $DEPLOY_SA_EMAIL
  WIF_PROVIDER          = $WIF_PROVIDER_RESOURCE

Next steps:

1. Fill in the real secret values (never paste these into chat):
     echo -n "sk-...."      | gcloud secrets versions add OPENAI_API_KEY --data-file=-
     echo -n "...."         | gcloud secrets versions add DEEPGRAM_API_KEY --data-file=-
     echo -n "...."         | gcloud secrets versions add PINECONE_API_KEY --data-file=-
     echo -n "...."         | gcloud secrets versions add REDIS_DB_PASSWORD --data-file=-
     openssl rand -hex 32   | gcloud secrets versions add ENCRYPTION_SECRET --data-file=-
     openssl rand -hex 16   | gcloud secrets versions add ADMIN_KEY --data-file=-

2. In your GitHub repo (srivinod1/omi) settings -> Secrets and variables -> Actions,
   add these repository VARIABLES (not secrets — they're not sensitive):
     GCP_PROJECT_ID       = $PROJECT_ID
     GCP_REGION            = $REGION
     GCP_WIF_PROVIDER     = $WIF_PROVIDER_RESOURCE
     GCP_DEPLOY_SA        = $DEPLOY_SA_EMAIL
     GCP_RUNTIME_SA       = $RUNTIME_SA_EMAIL
     PINECONE_INDEX_NAME  = <your Pinecone index name>
     REDIS_DB_HOST        = <your Upstash host>
     REDIS_DB_PORT        = <your Upstash port, usually 6379>

3. Push to the 'custom' branch to trigger .github/workflows/selfhost-deploy.yml.
================================================================================
EOF
