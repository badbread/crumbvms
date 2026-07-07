#!/usr/bin/env bash
# Gate the Rust backend on the build host, then deploy it to prod (the prod host).
#
#   backend.sh              gate (fmt+clippy+test) then deploy api+recorder
#   backend.sh --gate-only  only run the gate (no deploy)
#   backend.sh --no-gate    deploy without gating (use sparingly)
#   backend.sh --api-only   deploy only the api container (no recorder restart blip)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE=1; DEPLOY=1; SERVICES="api recorder"
for a in "$@"; do
  case "$a" in
    --gate-only) DEPLOY=0 ;;
    --no-gate)   GATE=0 ;;
    --api-only)  SERVICES="api" ;;
    *) die "backend.sh: unknown arg '$a'" ;;
  esac
done

if [ "$GATE" = 1 ]; then
  log "Backend gate on $DEV1 (fmt + clippy -D warnings + tests)"
  sync_to "$DEV1" "$GATE_DIR" "${BACKEND_PATHS[@]}"
  ssh "$DEV1" "cd ~/$GATE_DIR && cargo fmt --all -- --check \
    && cargo clippy --all-targets -- -D warnings \
    && cargo test --workspace" || die "gate failed — not deploying"
  ok "gate passed"
fi

if [ "$DEPLOY" = 1 ]; then
  log "Deploy backend to $PROD (build + up: $SERVICES)"
  sync_to "$PROD" "$PROD_APP" "${BACKEND_PATHS[@]}"
  ssh "$PROD" "cd $PROD_APP && docker compose build $SERVICES && docker compose up -d $SERVICES" \
    || die "prod deploy failed"
  ok "backend deployed ($SERVICES)"
fi
