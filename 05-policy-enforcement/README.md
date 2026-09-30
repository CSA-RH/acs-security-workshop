# Step 5 — Policy Enforcement: Guardrails as Code

## Summary

Findings alone do not reduce risk. This step turns the remediation plan from step 4 into **guardrails**
that stop new risk from entering the cluster. You define four RHACS policies as Kubernetes
`SecurityPolicy` custom resources (**policy as code**). The RHACS `config-controller` syncs them into
Central, so they can be versioned in Git and delivered with OpenShift GitOps. The policies then act
at two lifecycle stages:

- **Deploy stage**: the RHACS **admission controller** rejects non-compliant creates and updates
  (hard enforcement). Sensor scales existing violating deployments to zero (soft enforcement).
- **Build stage**: the same policies make `roxctl image check` fail in CI (used in step 7).

| File | Policy | Stages | Enforcement |
|---|---|---|---|
| `01-policy-fixable-important-cves.yaml` | Fixable CVEs of severity Important or higher (excludes `payments-api` as an accepted risk) | Build, Deploy | Fail build, scale to zero / block |
| `02-policy-log4shell.yaml` | Log4Shell CVE-2021-44228 | Build, Deploy | Fail build only; deploy is inform |
| `03-policy-privileged.yaml` | No privileged containers | Deploy | Scale to zero / block |
| `04-policy-trusted-registries.yaml` | Images from untrusted registries | Build, Deploy | Inform only |

All four are scoped to namespace `acs-workshop` for deploy-time evaluation, so they do not affect
other workloads on the cluster.

## Prerequisites

- [Step 4](../04-risk-analysis/) completed
- The admission controller runs with **enforcement enabled** (`spec.admissionControl.enforcement: Enabled`,
  set in [`01-setup/05-secured-cluster.yaml`](../01-setup/05-secured-cluster.yaml)). Check it in
  **Platform Configuration → Clusters → workshop-cluster → Static configuration → Admission controller
  enforcement behavior: Enforce policies**.
- Policy as code is enabled. It is the default: the `config-controller` pod runs in `stackrox`.
- `cluster-admin`, or write access to `securitypolicies.config.stackrox.io` in `stackrox`

## Steps

1. Apply the policies. They must be created in the namespace where Central runs:
   ```bash
   cd ../05-policy-enforcement
   oc --context security-ws apply -f .
   ```

2. Check that Central accepted each policy:
   ```bash
   oc --context security-ws get securitypolicies -n stackrox -l workshop=acs-vuln-mgmt \
     -o custom-columns=NAME:.metadata.name,ACCEPTED:.status.accepted,POLICY_ID:.status.policyId,MESSAGE:.status.message
   ```
   The policies now appear under **Platform Configuration → Policy Management**, marked as managed
   externally. Edits made in the portal are overwritten by the CR, and the CR is the source of truth.

3. **Enforce on existing deployments.** Policy changes act on running workloads only at the next
   Kubernetes event for them. To apply them now, go to **Policy Management** and click
   **Reassess All**. Then watch the result:
   ```bash
   oc --context security-ws get deploy -n acs-workshop -w
   ```
   Sensor scales `legacy-frontend` (fixable Important CVEs) and `node-agent` (privileged, and old
   image) to **0 replicas**. `payments-api` keeps running because it is covered by the exclusion.

4. **Hard enforcement at admission.** Try to create a new deployment from the vulnerable image:
   ```bash
   oc --context security-ws create deployment nginx-test -n acs-workshop --image=docker.io/library/nginx:1.22.0-alpine
   ```
   Then try to recreate the privileged agent:
   ```bash
   oc --context security-ws delete -f ../02-deploy-vulnerable-workloads/05-node-agent.yaml
   oc --context security-ws apply -f ../02-deploy-vulnerable-workloads/05-node-agent.yaml
   ```
   The API server rejects both requests. See the expected output below.

5. **Emergency bypass (break-glass).** Enforcement can be bypassed on purpose, and every bypass is
   audited:
   ```bash
   oc --context security-ws create deployment nginx-breakglass -n acs-workshop --image=docker.io/library/nginx:1.22.0-alpine \
     --dry-run=client -o yaml \
     | oc --context security-ws annotate --local -f - admission.stackrox.io/break-glass=TICKET-456 -o yaml \
     | oc --context security-ws apply -f -
   ```
   The deployment is admitted, and **Violations** shows a new *Emergency Deployment Annotation*
   alert. Remove it when you are done:
   `oc --context security-ws delete deployment nginx-breakglass -n acs-workshop`.

6. **Shift-left preview.** Run the same policies as a build-time check from the CLI:
   ```bash
   roxctl image check --insecure-skip-tls-verify \
     --image ghcr.io/christophetd/log4shell-vulnerable-app:latest --output table
   echo "exit code: $?"
   ```
   The 4.11 `roxctl deployment check --cluster` option evaluates a manifest *as if* it were
   deployed to a given cluster:
   ```bash
   roxctl deployment check --insecure-skip-tls-verify --cluster workshop-cluster \
     -f ../02-deploy-vulnerable-workloads/03-legacy-frontend.yaml --output table
   ```

## Expected Output

```text
$ oc --context security-ws get securitypolicies -n stackrox -l workshop=acs-vuln-mgmt -o custom-columns=...
NAME                              ACCEPTED   POLICY_ID                              MESSAGE
workshop-fixable-important-cves   true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
workshop-log4shell                true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
workshop-no-privileged            true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
workshop-trusted-registries       true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

$ oc --context security-ws get deploy -n acs-workshop          # after "Reassess All"
NAME              READY   UP-TO-DATE   AVAILABLE   AGE
legacy-frontend   0/0     0            0           40m
node-agent        0/0     0            0           40m
payments-api      1/1     1            1           40m

$ oc --context security-ws create deployment nginx-test -n acs-workshop --image=docker.io/library/nginx:1.22.0-alpine
error: failed to create deployment: admission webhook "policyeval.stackrox.io" denied the request:
The attempted operation violated 1 enforced policy, described below:

Policy: Workshop - Fixable CVEs of severity Important or higher
- Description:
    ↳ Image contains a fixable vulnerability with severity Important or Critical.
- Rationale:
    ↳ A fix is available. Running the vulnerable version is an avoidable risk.
- Remediation:
    ↳ Rebuild or rebase the image on a patched version ...
- Violations:
    - Fixable CVE-XXXX-XXXXX (CVSS X.X) (severity Important) found in component '...' ...

In case of emergency, add the annotation {"admission.stackrox.io/break-glass": "ticket-1234"} to your deployment with an updated ticket number

$ roxctl image check --image ghcr.io/christophetd/log4shell-vulnerable-app:latest
...
| Workshop - Log4Shell CVE-2021-44228 | CRITICAL | X | ... CVE-2021-44228 ... |
...
ERROR:  Violated a policy with CRITICAL severity ...
ERROR:  checking image failed: failed policies found: 2 policies violated that are failing the check
exit code: 1
```

The exact webhook message and CVE IDs depend on the current vulnerability feed. The important parts
are the `denied the request` message, the policy name, and the non-zero exit code from `roxctl`.

## Why This Works

- `SecurityPolicy` CRs are reconciled by `config-controller` into Central's policy store, so policy
  lifecycle follows the same Git review process as any other cluster configuration.
- The admission controller (a `ValidatingWebhookConfiguration`) evaluates deploy-stage policies that
  have enforcement enabled on every CREATE, UPDATE, and SCALE of a workload in scope. It uses image
  scan results that are already cached in Central.
- **Policy exclusions** turn a risk acceptance into an explicit, reviewable artifact. The
  `payments-api` exclusion sits in Git next to the policy, with a ticket reference. Exclusions also
  support an `expiration` timestamp, which makes the acceptance time-boxed and matches the 30-day CVE
  deferral from step 3.
- Namespaces such as `stackrox`, `kube-system`, and `kube-public` are always excluded from admission
  enforcement, so RHACS cannot block itself.

## Official Documentation

- [Using policies to provide security (policy structure, enforcement, admission controller, policy as code, criteria reference)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/using-policies-to-provide-security)
- [Checking policy compliance with roxctl (`image check`, `deployment check`)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/roxctl_cli/checking-policy-compliance-1)
- [Using RHACS with GitOps (delivering SecurityPolicy CRs with Argo CD)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/configuring/using-rhacs-with-gitops)
- [Responding to violations](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/respond-to-violations)

## Alternatives Considered

| Approach | Notes |
|---|---|
| RHACS `SecurityPolicy` CRs (this step) | Uses CVE and scan data, risk context, and build/deploy/runtime stages in one policy model. Git-native through the CRD. Scoped to what RHACS evaluates. |
| RHACS policies managed only in the portal | Fastest to try out. No Git history or review, and drift between clusters is harder to track. |
| OPA Gatekeeper / Kyverno admission policies | General-purpose Kubernetes policy engines. Good for configuration rules such as privileged pods or labels. They need an external data source to make CVE-based decisions. |
| OpenShift SCC plus Pod Security Admission only | Built into the platform and always on. Covers pod privileges but not image vulnerabilities or registries. Use it together with RHACS, not instead of it. |

## Clean Up

This removes the workshop policies and returns the application to its end-of-step-4 state: every
workload running, no enforcement. If you completed [step 6](../06-remediation/), run its clean-up
first. It ends by pointing back here.

```bash
# 1. Test deployments from steps 4 and 5 (they may not exist)
oc --context security-ws delete deployment nginx-test nginx-breakglass -n acs-workshop --ignore-not-found

# 2. Remove the policies. config-controller deletes them from Central.
oc --context security-ws delete securitypolicies.config.stackrox.io -n stackrox -l workshop=acs-vuln-mgmt --ignore-not-found

# 3. Check that Central no longer has them (needs ROX_ENDPOINT and ROX_API_TOKEN from step 1)
curl -sk -H "Authorization: Bearer ${ROX_API_TOKEN}" "https://${ROX_ENDPOINT}/v1/policies" \
  | jq -r '.policies[].name' | grep -c '^Workshop - '     # expected: 0
```

If the count is not `0`, wait about 30 seconds and check again. Sensor and the admission controller
receive the policy removal shortly after Central. Then restore the step 2 workloads. `node-agent`
was deleted in step 5 and its re-creation was blocked, and the other two were scaled to 0.
Recreating them gives a clean state:

```bash
# 4. Recreate the original vulnerable workloads (namespace, RBAC, and all three deployments)
oc --context security-ws delete deployment legacy-frontend node-agent -n acs-workshop --ignore-not-found
oc --context security-ws apply -f ../02-deploy-vulnerable-workloads/
oc --context security-ws get pods -n acs-workshop -w
```

If `oc apply` is still denied by `policyeval.stackrox.io`, the policy removal has not reached the
admission controller yet. Wait 30 seconds and run the command again.

Optional: in **Violations**, resolve the *Emergency Deployment Annotation* alert from step 5, part 5.

## Next

Continue with [`06-remediation/`](../06-remediation/).
