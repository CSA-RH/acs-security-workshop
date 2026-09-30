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
| Platform | Any OpenShift 4.19+ installation with internet access (AWS, bare metal, ROSA, ARO, and so on) |
| Sizing | At least 3 worker nodes with 4 vCPU / 16 GiB each. Central, Scanner V4, and the secured cluster services all run on the same cluster. |
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

```bash
oc delete project acs-workshop --ignore-not-found
oc delete securitypolicies.config.stackrox.io -n stackrox -l workshop=acs-vuln-mgmt
oc delete securedcluster --all -n stackrox && oc delete central --all -n stackrox
oc delete project stackrox rhacs-operator
```
