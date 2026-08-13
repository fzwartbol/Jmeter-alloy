#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/loki.yaml
kubectl apply -f k8s/alloy-central.yaml
kubectl apply -f k8s/grafana.yaml
kubectl apply -f k8s/test-app.yaml
kubectl apply -f k8s/jmeter-config.yaml
kubectl apply -f k8s/jmeter-run.yaml

echo "Infrastructure deployed. Start the load test with:"
echo "kubectl -n jmeter-live delete job jmeter-load --ignore-not-found"
echo "kubectl -n jmeter-live create -f k8s/jmeter-run.yaml"
