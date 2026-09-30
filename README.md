# Workshop: Vulnerability Management and Risk Mitigation with Red Hat Advanced Cluster Security 4.11

## Summary

A hands-on workshop covering the full vulnerability lifecycle on OpenShift with Red Hat Advanced
Cluster Security for Kubernetes (RHACS) 4.11. You install RHACS on a clean cluster and deploy a set
of intentionally vulnerable, misconfigured workloads (outdated NGINX, a Log4Shell-affected Java app,
a privileged "node agent"). Then you use RHACS to find their CVEs, prioritize them by real
deployment risk, and handle them with exceptions and reports. After that you enforce guardrails with
policy-as-code, fix the workloads (patched images, least privilege, network segmentation), and move
the same checks into any CI/CD tool with a portable `roxctl` gate, so vulnerable images are stopped
before they reach the cluster.

## Environment

| Item | Value |
|---|---|
| OpenShift version | OpenShift Container Platform 4.19+ (4.19 or later is required for the RHACS console plugin used in step 3) |
| RHACS | Red Hat Advanced Cluster Security for Kubernetes 4.11 (Operator, `stable` channel) with Scanner V4 |
| Platform | Any OpenShift 4.19+ installation with internet access. Tested footprint: ROSA with hosted control planes (HCP) and 2 worker nodes. |
| Sizing | Central, Scanner V4, and the secured cluster services all run on the same cluster. [`01-setup/04-central.yaml`](./01-setup/04-central.yaml) sets explicit requests and limits and disables the legacy StackRox Scanner, so everything fits on 2 worker nodes. |
| `oc` context | Every `oc` command uses `--context security-ws`. See [Quick Start](#quick-start). |
| CLI tools | `oc`, `roxctl` 4.11, `jq`, `curl` |

> **Warning:** This workshop deploys workloads that are vulnerable and over-privileged **on purpose**
> (Log4Shell, root containers, privileged pods). Use a disposable lab cluster only and never expose
> it to untrusted networks.

## Repository Structure

| Folder | Purpose |
|---|---|
| [`01-setup/`](./01-setup/) | Install the RHACS Operator, Central (with Scanner V4), and secured cluster services, then configure `roxctl` |
| [`02-deploy-vulnerable-workloads/`](./02-deploy-vulnerable-workloads/) | Deploy the intentionally vulnerable and misconfigured demo application |
| [`03-vulnerability-management/`](./03-vulnerability-management/) | Find, triage, and report CVEs: workload, platform, and node CVEs, `roxctl` scans, SBOMs, exceptions, scheduled reports |
| [`04-risk-analysis/`](./04-risk-analysis/) | Prioritize by risk: risk indicators, process discovery, network exposure, policy violations |
| [`05-policy-enforcement/`](./05-policy-enforcement/) | Add guardrails as code with `SecurityPolicy` CRs and admission-controller enforcement |
| [`06-remediation/`](./06-remediation/) | Fix and mitigate: patched images, least privilege, compensating network controls, then check that risk goes down |
| [`07-shift-left-ci-gate/`](./07-shift-left-ci-gate/) | Block vulnerable images before deploy with a CI-agnostic `roxctl` gate (`image check`, `deployment check`, SBOM, JUnit reports) |

## Quick Start

All `oc` commands in this workshop target the kubeconfig context `security-ws`, so they cannot hit
another cluster by accident. Create the context once after logging in to the workshop cluster:

```bash
oc login --server=https://api.<workshop-cluster-domain>:443 -u cluster-admin
oc config rename-context "$(oc config current-context)" security-ws
oc --context security-ws whoami --show-server
```

Start with [`01-setup/`](./01-setup/) on a clean cluster, then work through the folders in order.
Each step depends on the state left by the previous one. Plan for about 3 hours in total:

| Step | Duration |
|---|---|
| 01 | ~30 min (most of it is waiting for Central) |
| 02 | ~10 min |
| 03 | ~40 min |
| 04 | ~25 min |
| 05 | ~25 min |
| 06 | ~25 min |
| 07 | ~20 min |

```bash
git clone https://github.com/demon86rm/acs-security-workshop.git
cd acs-security-workshop/01-setup
```

## Clean Up

Every step folder ends with a **Clean Up** section. It undoes only that step, so you can repeat the
step without errors. Later steps build on earlier ones, so clean up in **reverse order** (07 → 01)
when you roll back more than one step.

To tear down the whole workshop, including RHACS, follow the
[step 1 Clean Up](./01-setup/README.md#clean-up). It also removes the policies from step 5 and the
application namespace from step 2, in a safe order.
