# Step 7 — Shift Left: a CI-Agnostic `roxctl` Security Gate

## Summary

Steps 5 and 6 stop and fix risk **at the cluster**. This step moves the same checks **earlier**, into
whatever CI/CD system the team already uses. RHACS exposes build-time and deploy-time policy
evaluation through the `roxctl` CLI, and its exit code works as a pass/fail gate. That means the
integration is a few shell lines with a tool-neutral contract: environment variables in, exit code
and report files out. Any CI/CD tool, or a developer laptop, can run it unchanged. The policies are
the ones defined as code in step 5, so the cluster and the pipeline enforce **one** rule set: an
image the admission controller would reject never gets built and promoted.

| Command | Evaluates | Fails the job when |
|---|---|---|
| `roxctl image scan` | CVEs in the image (report) | Never, in this gate. Use `--fail` if you want it to. |
| `roxctl image sbom` | SPDX SBOM of the image (artifact) | Never |
| `roxctl image check` | Policies with a **BUILD** lifecycle stage | A policy with *fail build* enforcement is violated |
| `roxctl deployment check` | Policies with a **DEPLOY** lifecycle stage against your manifests | A policy with deploy enforcement is violated |

## Prerequisites

- [Step 5](../05-policy-enforcement/) completed. The workshop policies exist with `FAIL_BUILD_ENFORCEMENT`.
- The CI runner can reach the Central Route over HTTPS (port 443)
- `bash` and `curl` on the runner image (for example `registry.access.redhat.com/ubi9/ubi`)
- Central can pull the image to scan. For private registries, add an image registry integration in
  **Platform Configuration → Integrations**.

## Files

| File | Role |
|---|---|
| `rox-ci-gate.sh` | Portable gate script (bash and curl only): downloads a version-matched `roxctl` from Central, writes reports (CSV, SBOM, JUnit), and exits non-zero on enforced violations |

## Steps

1. **Create a least-privilege CI token.** Use the built-in *Continuous Integration* role, not
   `Admin`. In the portal: **Platform Configuration → Integrations → API Token → Generate token**.
   Or from the workshop shell:
   ```bash
   export ROX_CI_TOKEN="$(curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" \
     "https://${ROX_ENDPOINT}/v1/apitokens/generate" \
     -d '{"name":"ci-gate","roles":["Continuous Integration"]}' | jq -r .token)"
   ```
   In a real pipeline, store it as a masked, protected CI secret called `ROX_API_TOKEN`, together
   with `ROX_ENDPOINT` (`<central-route-host>:443`).

2. **The gate as plain `roxctl` lines.** These are the commands to paste into any CI tool:
   ```bash
   # get a roxctl that matches Central
   curl -sSf -H "Authorization: Bearer ${ROX_API_TOKEN}" \
     "https://${ROX_ENDPOINT}/api/cli/download/roxctl-linux" -o roxctl && chmod +x roxctl

   # report: CVE list and SBOM (artifacts, never fail)
   ./roxctl image scan --image "$IMAGE" --output csv > image-scan.csv
   ./roxctl image sbom --image "$IMAGE" > sbom.spdx.json

   # gate 1: build-time policies (non-zero exit = job fails)
   ./roxctl image check --image "$IMAGE" --output junit > image-check.junit.xml

   # gate 2: deploy-time policies against the manifests you will deploy
   ./roxctl deployment check --cluster "$ROX_CLUSTER" -f k8s/deployment.yaml --output junit > deployment-check.junit.xml
   ```
   `--output` accepts `table`, `csv`, `json`, `junit`, and `sarif` for `image check` and
   `deployment check`. Pick the format your tooling reads: `junit` for CI test-report views, `sarif`
   for code-scanning and security dashboards, `json` for custom processing.

3. **Run the gate against the vulnerable image** (expected: **FAIL**). This simulates the CI job
   from your workstation:
   ```bash
   cd ../07-shift-left-ci-gate
   ROX_API_TOKEN="$ROX_CI_TOKEN" ROX_TLS_FLAG=--insecure-skip-tls-verify \
   IMAGE=ghcr.io/christophetd/log4shell-vulnerable-app:latest \
   MANIFESTS="../02-deploy-vulnerable-workloads/04-log4shell-app.yaml" \
   ROX_CLUSTER=workshop-cluster \
     ./rox-ci-gate.sh ; echo "exit code: $?"
   ```

4. **Run the gate against the remediated image and manifest** (expected: **PASS**):
   ```bash
   ROX_API_TOKEN="$ROX_CI_TOKEN" ROX_TLS_FLAG=--insecure-skip-tls-verify \
   IMAGE=registry.access.redhat.com/ubi9/nginx-124:latest \
   MANIFESTS="../06-remediation/02-legacy-frontend-hardened.yaml" \
   ROX_CLUSTER=workshop-cluster \
     ./rox-ci-gate.sh ; echo "exit code: $?"
   ```

5. Look at the reports in `rhacs-reports/`: `image-scan.csv`, `sbom.spdx.json`,
   `image-check.junit.xml`, `deployment-check.junit.xml`. These are the files a CI system archives
   and shows next to the change under review.

6. **Wire it into your CI/CD tool.** The script is the whole integration. Every CI tool needs the
   same four things:

   | Contract | What to configure in your tool |
   |---|---|
   | **Where** | One job or step **after** image build/push and **before** deploy or promote. The runner image needs `bash` and `curl` (for example `registry.access.redhat.com/ubi9/ubi`). |
   | **Inputs** | Secrets `ROX_ENDPOINT` and `ROX_API_TOKEN` from the tool's secret store (masked). Variables `IMAGE` (preferably the digest produced by the build), and optionally `MANIFESTS` and `ROX_CLUSTER`. |
   | **Run** | `./rox-ci-gate.sh`, copied into the application repo or a shared scripts repo |
   | **Outputs** | **Exit code**: non-zero means stop the pipeline. **Artifacts**: publish `rhacs-reports/` and feed the `*.junit.xml` files to the tool's test-report view. |

   Keep the job **blocking**. Do not mark it "allowed to fail". To make an exception, change the
   policy (scope, exclusion, or enforcement) in Git as in step 5, rather than bypassing the gate in
   one pipeline.

## Expected Output

```text
# Illustrative. Exact rows and counts depend on the current vulnerability feed.
# Step 3 (vulnerable)
Policy check results for image: ghcr.io/christophetd/log4shell-vulnerable-app:latest
(TOTAL: n, LOW: n, MEDIUM: n, HIGH: n, CRITICAL: n)
+----------------------------------------------+----------+--------------+---------------------------+-----+
|                    POLICY                    | SEVERITY | BREAKS BUILD |        DESCRIPTION        | ... |
+----------------------------------------------+----------+--------------+---------------------------+-----+
| Workshop - Log4Shell CVE-2021-44228          | CRITICAL |      X       | Image contains log4j-core |     |
| Workshop - Fixable CVEs of severity          | HIGH     |      X       | Image contains a fixable  |     |
|   Important or higher                        |          |              | vulnerability ...         |     |
| Workshop - Images from untrusted registries  | MEDIUM   |      -       | Image is pulled from ...  |     |
...
ERROR: checking image failed: failed policies found: 2 policies violated that are failing the check
RHACS gate: FAILED. Enforced policy violations found (see reports in rhacs-reports/).
exit code: 1

# Step 4 (remediated)
...
RHACS gate: PASSED
exit code: 0
```

Only policies with *fail build* enforcement break the build. The inform-only
*untrusted registries* policy is reported but does not fail the job. The exact CVE counts depend on
the current vulnerability feed.

> **Note on the `payments-api` exclusion:** `roxctl image check` evaluates the image with no
> deployment context. The deployment exclusion from step 5 therefore does not apply, and the Log4Shell
> image fails the build even though the running deployment is accepted. This is intended: the risk
> acceptance covers the existing workload, not new builds.

## Official Documentation

- [Integrating with CI systems](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/integrating/integrate-with-ci-systems)
- [Checking policy compliance with roxctl (`image check`, `deployment check`)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/roxctl_cli/checking-policy-compliance-1)
- [Image scanning by using the roxctl CLI](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/roxctl_cli/image-scanning-by-using-the-roxctl-cli-1)
- [roxctl CLI command reference](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/roxctl_cli/roxctl-cli-command-reference)
- [Configuring API tokens](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/configuring/configure-api-token)
- [Integrating with image registries](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/integrating/integrate-with-image-registries)
- [Generating SBOMs from scanned images](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/managing-vulnerabilities)

## Alternatives Considered

| Approach | Notes |
|---|---|
| `roxctl` in a shell step (this step) | Works with any CI tool. Version-matched `roxctl` downloaded from Central. Exit code is the gate. |
| `rhacs-roxctl-rhel9` container image | `registry.redhat.io/advanced-cluster-security/rhacs-roxctl-rhel9:4.11.4` has `roxctl` as its entrypoint. Good for CI tools that run a container per step. Needs `registry.redhat.io` credentials. |
| CI-tool-specific plugins or tasks | Tighter UI integration in one tool, but tied to that tool and its release cycle. They use the same RHACS API underneath. |
| Admission control only (step 5) | Still needed as the last line of defense, but developers only find out at deploy time. |

## Next

You have completed the workshop. See the [top-level README](../README.md#clean-up) for clean-up.
