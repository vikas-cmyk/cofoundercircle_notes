- **Groq STT on self-host Lite: probe and chunk no longer 403/400 the bot.** The STT health probe
  sends a curl User-Agent (Cloudflare was classifying Python-urllib as a bot) and uses
  `TRANSCRIPTION_MODEL`; the transcription client drops `timestamp_granularities` after a Groq
  `unknown_param` 400 instead of completing with zero segments. EC2 Lite+TLS compose lives at
  `deploy/ec2`. See [Vexa Lite](/deployment-lite).
