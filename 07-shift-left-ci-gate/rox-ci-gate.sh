#!/usr/bin/env bash
# rox-ci-gate.sh
# Purpose: CI-agnostic RHACS security gate. Needs only bash and curl, so it runs in any
# CI/CD system, in any container-based runner, or in a local shell.
#
# Required environment:
#   ROX_ENDPOINT   Central address as host:port, for example central-stackrox.apps.example.com:443
#   ROX_API_TOKEN  API token with the "Continuous Integration" role (store it as a masked CI secret)
#   IMAGE          Image to evaluate, ideally by digest (registry/repo@sha256:...)
# Optional:
#   MANIFESTS      Space-separated list of Kubernetes manifests to check against deploy-time policies
#   ROX_CLUSTER    Cluster name used as context for "roxctl deployment check" (4.11+)
#   REPORT_DIR     Where reports are written (default: ./rhacs-reports)
#   ROX_TLS_FLAG   Set to "--insecure-skip-tls-verify" only for labs with self-signed Central certs
#
# Exit code: 0 = gate passed; non-zero = an enforced BUILD or DEPLOY policy was violated
# (or roxctl could not reach Central). The CI job should fail on non-zero.
set -euo pipefail

: "${ROX_ENDPOINT:?ROX_ENDPOINT is required}"
: "${ROX_API_TOKEN:?ROX_API_TOKEN is required}"
: "${IMAGE:?IMAGE is required}"
REPORT_DIR="${REPORT_DIR:-rhacs-reports}"
ROX_TLS_FLAG="${ROX_TLS_FLAG:-}"
mkdir -p "${REPORT_DIR}"

# 1. Get a roxctl that matches the Central version (skip if roxctl is already on PATH).
if ! command -v roxctl >/dev/null 2>&1; then
  curl -sSf ${ROX_TLS_FLAG:+-k} -H "Authorization: Bearer ${ROX_API_TOKEN}" \
    "https://${ROX_ENDPOINT}/api/cli/download/roxctl-linux" -o ./roxctl
  chmod +x ./roxctl
  export PATH="${PWD}:${PATH}"
fi
roxctl version

# 2. Report only: full CVE list, SBOM (never fails the job, kept as CI artifacts).
roxctl image scan ${ROX_TLS_FLAG} --image "${IMAGE}" --force --output csv \
  > "${REPORT_DIR}/image-scan.csv" || echo "WARN: image scan failed"
roxctl image scan ${ROX_TLS_FLAG} --image "${IMAGE}" \
  --severity CRITICAL,IMPORTANT --output table || true
roxctl image sbom ${ROX_TLS_FLAG} --image "${IMAGE}" \
  > "${REPORT_DIR}/sbom.spdx.json" || echo "WARN: SBOM generation failed"

rc=0

# 3. Gate: build-time policies. Fails if a policy with "fail build" enforcement is violated.
roxctl image check ${ROX_TLS_FLAG} --image "${IMAGE}" --output junit \
  > "${REPORT_DIR}/image-check.junit.xml" || rc=1
roxctl image check ${ROX_TLS_FLAG} --image "${IMAGE}" --output table || true

# 4. Gate: deploy-time policies against the manifests that will be deployed.
if [[ -n "${MANIFESTS:-}" ]]; then
  file_args=()
  for m in ${MANIFESTS}; do file_args+=(-f "$m"); done
  roxctl deployment check ${ROX_TLS_FLAG} ${ROX_CLUSTER:+--cluster "${ROX_CLUSTER}"} \
    "${file_args[@]}" --output junit > "${REPORT_DIR}/deployment-check.junit.xml" || rc=1
  roxctl deployment check ${ROX_TLS_FLAG} ${ROX_CLUSTER:+--cluster "${ROX_CLUSTER}"} \
    "${file_args[@]}" --output table || true
fi

if [[ $rc -ne 0 ]]; then
  echo "RHACS gate: FAILED. Enforced policy violations found (see reports in ${REPORT_DIR}/)."
else
  echo "RHACS gate: PASSED"
fi
exit $rc
