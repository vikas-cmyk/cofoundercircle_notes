# Vexa Lite on one EC2

Single-box production: **Lite + Postgres + MinIO + Caddy**. The only public surface is the
gateway on **443**. Terminal (`:3001`) and agent-api (`:8100`) are not published — Cofounder
Circle talks to Vexa over `POST /meetings` / `GET /transcripts`, never the Vexa UI.

This is the path that matches the local Lite you already ran. Full Compose (`make all`) is a
different stack and currently depends on unpublished `vexaai/v012-flows` images.

## Box

| | |
|---|---|
| OS | Ubuntu 24.04 LTS, **amd64** |
| Size | 4 vCPU / **16 GB RAM** (Playwright bots share this box; 8 GB is tight) |
| Disk | **100 GB gp3** — recordings live in MinIO; an 80 GB volume filled during local tests |
| Network | Security group: **22, 80, 443** inbound. No 8056/3001/8100 from the internet |
| DNS | A-record for `VEXA_DOMAIN` → this instance (or Elastic IP) **before** bootstrap |

Do not use ARM/Graviton for this shape unless you have already proven Meet join on that
architecture. Lite images are multi-arch; Meet bots are the risk.

## On the instance

```bash
sudo apt-get update && sudo apt-get install -y git curl openssl
# copy this checkout onto the box (scp/rsync the zip, or git clone if you have a remote)
cd /opt/vexa   # or wherever the tree lives
cp deploy/ec2/.env.example deploy/ec2/.env
```

Edit `deploy/ec2/.env`:

1. `VEXA_DOMAIN` + `ACME_EMAIL` + `VEXA_PUBLIC_API_URL=https://<that-domain>`
2. `TRANSCRIPTION_SERVICE_TOKEN` — Groq `gsk_…`
3. Leave `ADMIN_TOKEN` / `INTERNAL_API_SECRET` / DB / MinIO keys **empty** — `bootstrap.sh` mints them

Groq URL must stay **`https://api.groq.com/openai`** (no `/v1`). The bot appends
`/v1/audio/transcriptions`. Adding `/v1` yourself double-paths the request.

```bash
sudo deploy/ec2/bootstrap.sh
sudo deploy/ec2/print-api-key.sh
```

Store the printed `VEXA_API_KEY` on the Cofounder Circle backend as `VEXA_API_KEY`. Backend
`VEXA_API_URL` is `https://<VEXA_DOMAIN>` (no path, no trailing slash).

## What the backend sends

```http
POST https://<VEXA_DOMAIN>/meetings
X-API-Key: vxa_...
Content-Type: application/json

{
  "title": "Weekly",
  "meeting_url": "https://meet.google.com/abc-defg-hij",
  "scheduled_at": "2026-09-08T10:00:00Z",
  "auto_join": true
}
```

Lite's sweep joins **120s before** `scheduled_at` and gives up if the start is more than **10 min**
past. The guest is named `DEFAULT_BOT_NAME` (Cofounder Circle Notes). It leaves **1 minute** after
the room empties (`BOT_ALONE_SILENCE_WINDOW_MS=60000`). The host must **Admit** the guest.

`POST /meetings` does not take `bot_name`; the env default is what auto-join uses. A manual
`POST /bots` may still pass `"bot_name": "Cofounder Circle Notes"`.

## Groq patches (why overlay exists)

The published `vexaai/vexa-lite:v012` image:

1. Probes STT with Python-urllib's User-Agent — Cloudflare in front of Groq returns **403** and
   Lite then refuses `POST /bots` (`unauthorized`).
2. Sends `timestamp_granularities=word` on every chunk — Groq returns **400** `unknown_param` and
   the meeting completes with **0 segments**.

`overlay/patch-image.sh` copies those two files out of the image, patches them, and compose
bind-mounts the result. Re-run it after you bump `IMAGE_TAG`. Source in this tree already has
the same fixes for a future Lite rebuild.

## Ops

```bash
cd deploy/ec2
docker compose logs -f vexa
docker compose exec vexa supervisorctl status
./print-api-key.sh
docker compose down          # volumes kept
```

Watch disk: `df -h` and `docker system df`. MinIO lives in the `vexa-miniodata` volume.

## What this does not do

- No Vexa Terminal OAuth, no Google tokens in Vexa — Calendar stays on your backend.
- No authenticated (signed-in) Meet bot.
- No clock-time leave at "meeting end"; leave is `left_alone` after the room empties, or
  `DELETE /bots/{platform}/{native_meeting_id}` from your backend.
