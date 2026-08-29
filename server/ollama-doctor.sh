#!/usr/bin/env bash
# ollama-doctor — check and, when needed, restart the ollama service.
#
# Grants: if /etc/sudoers.d/ollama-restart is installed (see
# sudoers-ollama-restart in this dir), this can restart the service without a
# password. Otherwise it diagnoses and tells you the one command to run.
#
# Usage:
#   ollama-doctor.sh          # diagnose; restart only if unhealthy
#   ollama-doctor.sh --force  # restart unconditionally
set -u

PORT="${OLLAMA_HOST:-http://localhost:11434}"
say() { printf '%s\n' "$*"; }

# --- diagnose -----------------------------------------------------------------
api_ok() { curl -s -m 5 "$PORT/api/version" >/dev/null 2>&1; }

gpu_ok() {
  # A loaded model with size_vram == 0 means CUDA died server-side (the §11o
  # dead-CUDA failure: model pinned 100% CPU). With nothing loaded we can't
  # judge — so WARM-LOAD the 4b first (tiny ctx, one token) and then judge.
  local procs
  procs=$(curl -s -m 5 "$PORT/api/ps" 2>/dev/null) || return 0
  if ! echo "$procs" | grep -q '"name"'; then
    curl -s -m 120 "$PORT/api/chat" -d '{"model":"qwen3.5:4b","messages":[{"role":"user","content":"hi"}],"stream":false,"think":false,"options":{"num_predict":1,"num_ctx":2048}}' >/dev/null 2>&1
    procs=$(curl -s -m 5 "$PORT/api/ps" 2>/dev/null) || return 0
  fi
  echo "$procs" | grep -q '"name"' || return 0   # still nothing (no models?) — can't judge
  # any loaded model fully off-GPU (size_vram == 0, compact OR spaced JSON) => unhealthy
  if echo "$procs" | grep -qE '"size_vram": ?0[,}]'; then
    return 1
  fi
  return 0
}

healthy() { api_ok && gpu_ok; }

if [ "${1:-}" != "--force" ]; then
  if healthy; then
    say "ollama-doctor: OK (api up, models on GPU where loaded)"
    exit 0
  fi
  say "ollama-doctor: UNHEALTHY — api_ok=$(api_ok && echo yes || echo no)"
fi

# --- restart ------------------------------------------------------------------
if sudo -n systemctl restart ollama 2>/dev/null; then
  say "ollama-doctor: restarted ollama.service, waiting for api..."
else
  say "ollama-doctor: cannot restart without a password."
  say "  One-time fix: install the sudoers snippet, then I can always do this:"
  say "    sudo install -m 440 -o root -g root \\"
  say "      ~/Projects/anytimelime-trio/anytimelime/server/sudoers-ollama-restart \\"
  say "      /etc/sudoers.d/ollama-restart"
  say "  Or right now:  sudo systemctl restart ollama"
  exit 1
fi

for _ in $(seq 1 15); do
  sleep 2
  api_ok && break
done
if api_ok; then
  say "ollama-doctor: service back up at $PORT"
  exit 0
fi
say "ollama-doctor: service still not answering after 30s — check: journalctl -u ollama -n 50"
exit 1
