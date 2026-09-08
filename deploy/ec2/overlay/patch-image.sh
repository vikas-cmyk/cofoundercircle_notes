#!/usr/bin/env bash
# Extract STT files from the published Lite image and apply Groq-compat patches.
# Bind-mounted by docker-compose.yml so a recreate keeps the fix without rebuilding Lite.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
set -a
[ -f .env ] && . ./.env
set +a
IMAGE="${VEXA_IMAGE:-cofoundercircle/vexa-lite:test}"
OUT="$ROOT/overlay/generated"
mkdir -p "$OUT"

echo "Pulling $IMAGE ..."
docker pull "$IMAGE" >/dev/null
cid="$(docker create "$IMAGE")"
cleanup() { docker rm -f "$cid" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker cp "$cid:/app/core/meetings/modules/whisper/dist/transcription-client.js" \
  "$OUT/transcription-client.js"
docker cp "$cid:/app/meeting-api/src/meeting_api/config_preflight.py" \
  "$OUT/config_preflight.py"

python3 - "$OUT/transcription-client.js" "$OUT/config_preflight.py" <<'PY'
import re, pathlib, sys

js = pathlib.Path(sys.argv[1])
py = pathlib.Path(sys.argv[2])

text = js.read_text()
# Drop the 4-line word-timestamp form part. Groq 400s `unknown param timestamp_granularities`.
pat = re.compile(
    r"\s*// Request word-level timestamps\s*"
    r"parts\.push\(Buffer\.from\(`--\$\{boundary\}\\r\\n` \+\s*"
    r"`Content-Disposition: form-data; name=\"timestamp_granularities\"\\r\\n\\r\\n` \+\s*"
    r"`word\\r\\n`\)\);",
    re.M,
)
text2, n = pat.subn("\n", text, count=1)
if n == 0 and "timestamp_granularities" in text:
    # Broader: drop any form-part that names the param.
    pat2 = re.compile(
        r"parts\.push\(Buffer\.from\(`--\$\{boundary\}\\r\\n` \+\s*"
        r"`Content-Disposition: form-data; name=\"timestamp_granularities\"\\r\\n\\r\\n` \+\s*"
        r"`word\\r\\n`\)\);",
        re.M,
    )
    text2, n = pat2.subn("", text, count=1)
if "timestamp_granularities" in text2:
    raise SystemExit("failed to strip timestamp_granularities from transcription-client.js")
if n:
    js.write_text(text2)
    print("patched transcription-client.js (removed timestamp_granularities)")
else:
    print("transcription-client.js already has no timestamp_granularities")

p = py.read_text()
changed = False
if 'req.add_header("User-Agent"' not in p and "User-Agent" not in p.split("def _http_probe", 1)[-1][:2500]:
    needle = 'req.add_header("Content-Type", content_type)'
    if needle not in p:
        raise SystemExit("config_preflight.py: Content-Type header site not found")
    p = p.replace(
        needle,
        needle + "\n    req.add_header(\"User-Agent\", \"curl/8.7.1\")",
        1,
    )
    changed = True
old = 'content_type, body = audio_probe_body(spec.get("payload_model") or "whisper-1")'
new = (
    'model = (env.get("TRANSCRIPTION_MODEL") or spec.get("payload_model") or "whisper-1").strip() or "whisper-1"\n'
    "        content_type, body = audio_probe_body(model)"
)
if old in p:
    p = p.replace(old, new, 1)
    changed = True
if changed:
    py.write_text(p)
    print("patched config_preflight.py (User-Agent + TRANSCRIPTION_MODEL)")
else:
    print("config_preflight.py already patched")
PY

echo "overlay ready in $OUT"
