# External accounts you need to create

I can't sign up for these on your behalf (account creation is something only
you can do). Free tiers exist for all four. Once you have them, hand me the
values and I'll load them into Secret Manager for you — nothing gets typed
into chat by hand if you'd rather paste directly into `gcloud` yourself.

## 1. OpenAI
- Sign up: https://platform.openai.com/signup
- Create a key: https://platform.openai.com/settings/organization/api-keys
- Needed: `OPENAI_API_KEY`
- This is billed pay-as-you-go; add a small amount of credit.

## 2. Deepgram (speech-to-text)
- Sign up: https://console.deepgram.com/signup
- Free tier includes trial credit.
- Needed: `DEEPGRAM_API_KEY`

## 3. Pinecone (vector DB — required just to boot)
- Sign up: https://app.pinecone.io/
- Create an index:
  - Name it e.g. `omi-memories`
  - Dimension: **1536** (matches OpenAI's `text-embedding-3-small`)
  - Metric: cosine
  - Serverless (free tier eligible)
- Needed: `PINECONE_API_KEY`, `PINECONE_INDEX_NAME`

## 4. Upstash Redis
- Sign up: https://console.upstash.com/
- Create a Redis database (free tier is fine for a single device), enable TLS.
- From its details page, needed: `REDIS_DB_HOST`, `REDIS_DB_PORT` (usually
  `6379` with TLS), `REDIS_DB_PASSWORD`

## Optional (skip for now, add later if you want the feature)
- **ElevenLabs** (`ELEVENLABS_API_KEY`) — TTS for spoken responses
- **Google OAuth** (`GOOGLE_CLIENT_ID`/`SECRET`) — Google Calendar integration
- **Stripe**, **Twilio**, **Notion**, **Twitter/X**, **Whoop** — respective integrations
