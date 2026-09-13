# Self-hosting Omi on GCP

This directory (`selfhost/`) holds everything specific to *your* deployment.
It's kept isolated from the rest of the tree on purpose so that pulling in
upstream (BasedHardware) changes never conflicts with it — see
[sync-upstream.sh](sync-upstream.sh).

## How this fork is organized

- `main` — pristine mirror of `upstream` (BasedHardware/omi). Never commit here.
- `custom` — your changes, rebased on `main`. This is the branch that gets deployed.
- `selfhost/sync-upstream.sh` — pulls the latest upstream release into `custom`.

To pull in a new Omi release later:
```bash
./selfhost/sync-upstream.sh
```

## What actually gets deployed

Omi's own production setup (`infrastructure/opentofu`, `backend/charts`) is a
whole GKE fleet (diarizer, parakeet ASR, llm-gateway, translation, etc.) wired
to BasedHardware's own GCP project and GitHub org. That's not something a
personal self-host should replicate.

Instead we deploy the two services a single device actually needs, as plain
Cloud Run services, using hosted third-party APIs instead of BasedHardware's
internal microservices:

| Service | Source | Purpose |
|---|---|---|
| `omi-backend` | `backend/` (`backend/Dockerfile`) | Main API the app/device talks to (`BASE_API_URL`) |
| `omi-pusher`  | `backend/pusher/` (`backend/pusher/Dockerfile`) | Finalizes conversations after a listen session ends. Required — without it, conversations stay stuck "in_progress". |

Both use: **Firestore** (DB) + **Firebase Auth** (users) + **Cloud Storage**
(audio/speech-profile buckets) + **Secret Manager** (credentials), all in your
own GCP project, plus these external hosted services (bring your own keys):

- **OpenAI** — LLM calls
- **Deepgram** — speech-to-text
- **Pinecone** — vector search for memories. **Note:** the backend calls
  `pinecone.describe_index()` at *import time* (`database/vector_db.py`), so a
  valid Pinecone key + an already-created index are required just for the
  process to boot, not only for memory features to work.
- **Upstash Redis** (or any TLS-reachable Redis) — caching/session state

Skipped/left off for a personal deployment: self-hosted Parakeet ASR,
diarizer, llm-gateway, NLLB translation, deepgram-self-hosted, Stripe billing,
Twilio phone calls, and other integrations gated behind their own env vars —
all optional and off by default.

## Setup order

1. **External accounts** (`selfhost/EXTERNAL_ACCOUNTS.md`) — OpenAI, Deepgram,
   Pinecone, Upstash. Get the keys before touching GCP; the backend won't boot
   without a real Pinecone key.
2. **GCP project** (`selfhost/gcp-bootstrap.sh`) — one-time: creates the
   project, enables APIs, Firestore, buckets, Artifact Registry, service
   accounts, Workload Identity Federation for GitHub Actions, and empty
   Secret Manager entries.
3. **Firebase** — enable Firebase on the project via the console (needed for
   Firebase Auth token verification); see the bootstrap script's printed
   instructions.
4. **Secrets** — fill in the Secret Manager entries the bootstrap script
   created, with your real API keys.
5. **Deploy** — push to `custom`; GitHub Actions (`.github/workflows/selfhost-deploy.yml`)
   builds both images and deploys them to Cloud Run.
6. **Point the app at it** — set `BASE_API_URL` in the Omi mobile/desktop app
   to your Cloud Run `omi-backend` URL.
