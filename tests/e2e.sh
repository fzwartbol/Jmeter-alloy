#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-jmeter-live}"
JOB="${JOB:-jmeter-load}"
LOCAL_PORT="${LOCAL_PORT:-3100}"

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Waiting for target application..."
kubectl -n "$NAMESPACE" rollout status deployment/test-app --timeout=120s

echo "Waiting for central Alloy..."
kubectl -n "$NAMESPACE" rollout status deployment/alloy-central --timeout=120s

echo "Waiting for Loki..."
kubectl -n "$NAMESPACE" rollout status deployment/loki --timeout=120s

echo "Starting JMeter..."
kubectl -n "$NAMESPACE" delete job "$JOB" --ignore-not-found=true >/dev/null
kubectl -n "$NAMESPACE" create -f k8s/jmeter-run.yaml

kubectl -n "$NAMESPACE" port-forward svc/loki "$LOCAL_PORT":3100 >/tmp/jmeter-loki-port-forward.log 2>&1 &
PF_PID=$!
sleep 2

query() {
  curl -fsS --get "http://127.0.0.1:${LOCAL_PORT}/loki/api/v1/query" --data-urlencode "query=$1"
}

wait_for_samples() {
  local query_string="$1"
  for _ in $(seq 1 90); do
    if response=$(query "$query_string" 2>/dev/null) \
      && [[ "$response" == *'"result"'* ]] \
      && [[ "$response" != *'"result":[]'* ]]; then
      printf '%s' "$response"
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "Waiting for JMeter samples in Loki..."
if ! response=$(wait_for_samples '{job="jmeter"}'); then
  echo "ERROR: no JMeter samples found in Loki within 90s" >&2
  echo "Loki port-forward log:" >&2
  cat /tmp/jmeter-loki-port-forward.log >&2 || true
  exit 1
fi

echo "JMeter samples found in Loki."

if [[ "$response" != *'"success":"true"'* ]]; then
  echo "ERROR: expected success=true label not found" >&2
  exit 1
fi

if [[ "$response" != *'"code":"200"'* ]]; then
  echo "ERROR: expected code=200 label not found" >&2
  exit 1
fi

if [[ "$response" != *'"label":"GET /api/test"'* ]]; then
  echo "ERROR: expected label=GET /api/test label not found" >&2
  exit 1
fi

metadata_query='{job="jmeter"} | unwrap elapsed | sum_over_time([5m])'
if ! metadata_response=$(query "$metadata_query" 2>/dev/null); then
  echo "ERROR: elapsed structured metadata cannot be queried" >&2
  exit 1
fi

if [[ "$metadata_response" == *'"result":[]'* ]]; then
  echo "ERROR: elapsed query returned no samples" >&2
  exit 1
fi

echo "Waiting for JMeter Job completion..."
kubectl -n "$NAMESPACE" wait --for=condition=complete job/$JOB --timeout=120s

echo "E2E test passed: JMeter -> JTL -> Alloy sidecar -> central Alloy -> Loki -> LogQL"
