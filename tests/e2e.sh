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
kubectl -n "$NAMESPACE" create -f k8s/jmeter-job.yaml

kubectl -n "$NAMESPACE" port-forward svc/loki "$LOCAL_PORT":3100 >/tmp/jmeter-loki-port-forward.log 2>&1 &
PF_PID=$!
sleep 2

query() {
  curl -fsS --get "http://127.0.0.1:${LOCAL_PORT}/loki/api/v1/query" --data-urlencode "query=$1"
}

echo "Waiting for JMeter samples in Loki..."
for _ in $(seq 1 60); do
  if response=$(query '{job="jmeter"}' 2>/dev/null) && [[ "$response" == *"result"* ]] && [[ "$response" != *'"result":[]'* ]]; then
    echo "JMeter samples found in Loki."
    break
  fi
  sleep 1
done

response=$(query '{job="jmeter"}')
if [[ "$response" == *'"result":[]'* ]]; then
  echo "ERROR: no JMeter samples found in Loki" >&2
  exit 1
fi

if [[ "$response" != *'"success"'* ]]; then
  echo "ERROR: success label not found" >&2
  exit 1
fi

if [[ "$response" != *'"label"'* ]]; then
  echo "ERROR: label not found" >&2
  exit 1
fi

metadata_query='{job="jmeter"} | unwrap elapsed'
if ! query "$metadata_query" >/tmp/jmeter-loki-metadata.json 2>/dev/null; then
  echo "ERROR: elapsed cannot be queried/unwrapped" >&2
  exit 1
fi

if ! grep -q 'result' /tmp/jmeter-loki-metadata.json; then
  echo "ERROR: elapsed query returned no result structure" >&2
  exit 1
fi

echo "Waiting for JMeter Job completion..."
kubectl -n "$NAMESPACE" wait --for=condition=complete job/$JOB --timeout=120s

echo "E2E test passed: JMeter -> JTL -> Alloy sidecar -> central Alloy -> Loki -> LogQL"
