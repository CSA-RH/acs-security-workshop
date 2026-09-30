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
   oc apply -f .
   ```

2. Check that Central accepted each policy:
   ```bash
   oc get securitypolicies -n stackrox -l workshop=acs-vuln-mgmt \
     -o custom-columns=NAME:.metadata.name,ACCEPTED:.status.accepted,POLICY_ID:.status.policyId,MESSAGE:.status.message
   ```
   The policies now appear under **Platform Configuration → Policy Management**, marked as managed
   externally. Edits made in the portal are overwritten by the CR, and the CR is the source of truth.

3. **Enforce on existing deployments.** Policy changes act on running workloads only at the next
   Kubernetes event for them. To apply them now, go to **Policy Management** and click
   **Reassess All**. Then watch the result:
   ```bash
   oc get deploy -n acs-workshop -w
   ```
   Sensor scales `legacy-frontend` (fixable Important CVEs) and `node-agent` (privileged, and old
   image) to **0 replicas**. `payments-api` keeps running because it is covered by the exclusion.

4. **Hard enforcement at admission.** Try to create a new deployment from the vulnerable image:
   ```bash
   oc create deployment nginx-test -n acs-workshop --image=docker.io/library/nginx:1.14.0
   ```
   Then try to recreate the privileged agent:
   ```bash
   oc delete -f ../02-deploy-vulnerable-workloads/05-node-agent.yaml
   oc apply  -f ../02-deploy-vulnerable-workloads/05-node-agent.yaml
   ```
   The API server rejects both requests. See the expected output below.

5. **Emergency bypass (break-glass).** Enforcement can be bypassed on purpose, and every bypass is
   audited:
   ```bash
   oc create deployment nginx-breakglass -n acs-workshop --image=docker.io/library/nginx:1.14.0 \
     --dry-run=client -o yaml \
     | oc annotate --local -f - admission.stackrox.io/break-glass=TICKET-456 -o yaml \
     | oc apply -f -
   ```
   The deployment is admitted, and **Violations** shows a new *Emergency Deployment Annotation*
   alert. Remove it when you are done:
   `oc delete deployment nginx-breakglass -n acs-workshop`.

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
$ oc get securitypolicies -n stackrox -l workshop=acs-vuln-mgmt -o custom-columns=...
NAME                              ACCEPTED   POLICY_ID                              MESSAGE
workshop-fixable-important-cves   true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
workshop-log4shell                true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
workshop-no-privileged            true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
workshop-trusted-registries       true       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

$ oc get deploy -n acs-workshop          # after "Reassess All"
NAME              READY   UP-TO-DATE   AVAILABLE   AGE
legacy-frontend   0/0     0            0           40m
node-agent        0/0     0            0           40m
payments-api      1/1     1            1           40m

$ oc create deployment nginx-test -n acs-workshop --image=docker.io/library/nginx:1.14.0
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

## Next

Continue with [`06-remediation/`](../06-remediation/).
