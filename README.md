# JMeter → Alloy → Loki live results demo

Small Kubernetes example that streams JMeter JTL results into Loki through a local Alloy sidecar and a central Alloy gateway, then visualizes the results in Grafana.

## Architecture

```text
JMeter Job
  │
  │ results.jtl
  ▼
shared emptyDir
  │
  ▼
Alloy sidecar
  │ Loki push API
  ▼
Central Alloy
  │
  ▼
Loki
  │
  ▼
Grafana
```

The project intentionally does **not** use InfluxDB or Prometheus for JMeter results. The JTL is tailed as a live log stream so Grafana can query short windows without depending on a one-minute metrics resolution.

## Requirements

- Kubernetes >= 1.29 for native sidecars
- `kubectl`
- A cluster capable of running Loki, Grafana, Alloy and JMeter

## Deploy

```bash
kubectl apply -f k8s/
```

Or run `./deploy.sh`, which applies the manifests in dependency order and prints the commands to start a test run.

Wait for the infrastructure:

```bash
kubectl -n jmeter-live get pods
```

Start a test:

```bash
kubectl -n jmeter-live delete job jmeter-load --ignore-not-found
kubectl -n jmeter-live create -f k8s/jmeter-job.yaml
```

Watch it:

```bash
kubectl -n jmeter-live logs -f job/jmeter-load -c jmeter
```

## Grafana

Port-forward Grafana:

```bash
kubectl -n jmeter-live port-forward svc/grafana 3000:3000
```

Open `http://localhost:3000`.

The dashboard is provisioned automatically and uses Loki.

## LogQL examples

Requests/sec:

```logql
sum by (label) (rate({job="jmeter"}[30s]))
```

P95 response time:

```logql
quantile_over_time(0.95, {job="jmeter"} | unwrap elapsed [30s])
```

Error rate:

```logql
sum(rate({job="jmeter", success="false"}[30s]))
/
sum(rate({job="jmeter"}[30s])) * 100
```

## End-to-end test

The E2E script starts a JMeter Job, waits for samples to arrive in Loki and verifies that the parsed labels and `elapsed` metadata are queryable.

```bash
./tests/e2e.sh
```

The script assumes the resources have already been deployed and that `kubectl` points at the target cluster.

## Design notes

- JMeter writes tab-delimited JTL.
- `autoflush=true` is enabled to reduce tail latency.
- Alloy uses the JMeter sample timestamp, not ingestion time.
- Low-cardinality fields are Loki labels.
- Numeric fields such as `elapsed` and `bytes` are structured metadata and are not labels.
- The JTL volume is an `emptyDir`; it is not intended as persistent storage.
- One Loki record is generated per JMeter sample, so high-TPS tests can generate substantial Loki ingestion volume.
