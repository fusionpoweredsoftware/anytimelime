# anytimelime server — self-sustaining free-model discovery loop.
# A free model, running on free models, finds free models.
FROM alpine:3.20

RUN apk add --no-cache bash curl jq python3 coreutils

WORKDIR /app

# Build context is the repo ROOT (see docker-compose.yml), so engine scripts
# are copied from the top level and server files from server/. This used to
# copy all four from the root, where entrypoint.sh and proxy.py have never
# lived — the documented build command failed outright.
COPY free-scan.sh synthesize.sh /app/
COPY server/entrypoint.sh server/proxy.py /app/
RUN chmod +x /app/*.sh && mkdir -p /app/public

# Logs + generated config land here; mount a volume to persist.
VOLUME /app/public

EXPOSE 8042 8043

ENTRYPOINT ["/app/entrypoint.sh"]
