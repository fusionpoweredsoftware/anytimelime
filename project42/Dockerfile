# Project 42 — self-sustaining free-model discovery loop.
# A free model, running on free models, finds free models.
FROM alpine:3.20

RUN apk add --no-cache bash curl jq python3 coreutils

WORKDIR /app

# Scripts live one level up from this docker context (../)
COPY free-scan.sh synthesize.sh entrypoint.sh proxy.py /app/
RUN chmod +x /app/*.sh && mkdir -p /app/public

# Logs + generated config land here; mount a volume to persist.
VOLUME /app/public

EXPOSE 8042

ENTRYPOINT ["/app/entrypoint.sh"]
