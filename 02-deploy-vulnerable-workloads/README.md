# Step 2 — Deploy the Vulnerable Workloads

## Description

This step deploys **acs-workshop**, a small and deliberately insecure application that gives RHACS
real findings to work with in the rest of the workshop. It has three components. Each one shows a
different mix of *vulnerability* (CVEs in the image) and *configuration risk* (privileges, exposure,
secrets). Telling these two apart is the core idea of risk-based vulnerability management.

| Deployment | Image | Vulnerability profile | Configuration risk |
|---|---|---|---|
| `legacy-frontend` | `docker.io/library/nginx:1.14.0` | Outdated Debian 9 base, hundreds of CVEs, many fixable | Root user (anyuid SCC), plaintext secret in an env var, no resource limits, **internet-facing Route** |
| `payments-api` | `ghcr.io/christophetd/log4shell-vulnerable-app` | **CVE-2021-44228 (Log4Shell)** and other Java CVEs | Default restricted SCC, internal only |
| `node-agent` | `registry.access.redhat.com/ubi8/ubi:8.0` | Outdated 2019 UBI 8.0 base | **Privileged**, host PID and network, host `/` mounted, privileged SCC |

> **Warning:** These workloads are exploitable on purpose. Deploy them only on a disposable lab
> cluster.

## Prerequisites

- [Step 1](../01-setup/) completed: RHACS Central and secured cluster services are healthy
- `oc` logged in as `cluster-admin` (needed to bind the `anyuid` and `privileged` SCCs)
- The cluster can pull from `docker.io`, `ghcr.io`, and `registry.access.redhat.com`

## Files

| File | Role |
|---|---|
| `01-namespace.yaml` | `acs-workshop` namespace, with Pod Security Admission set to `privileged` on purpose |
| `02-rbac.yaml` | ServiceAccounts and RoleBindings that grant the `anyuid` and `privileged` SCCs |
| `03-legacy-frontend.yaml` | NGINX 1.14 Deployment, Service, and edge Route |
| `04-log4shell-app.yaml` | Log4Shell-affected Spring Boot Deployment and Service |
| `05-node-agent.yaml` | Privileged, host-mounted "agent" Deployment |

## Steps

1. Deploy everything:
   ```bash
   cd ../02-deploy-vulnerable-workloads
   oc --context security-ws apply -f .
   ```

2. Wait for the pods:
   ```bash
   oc --context security-ws get pods -n acs-workshop -w
   ```

3. Check that the frontend is reachable from the internet:
   ```bash
   curl -sI "https://$(oc --context security-ws get route legacy-frontend -n acs-workshop -o jsonpath='{.spec.host}')" | head -3
   ```

4. Give Sensor about 1–2 minutes to report the deployments and Scanner V4 time to index the three
   images. Then check that RHACS has scanned them:
   ```bash
   roxctl deployment check --insecure-skip-tls-verify -f 03-legacy-frontend.yaml --output table | head -20
   ```

## Expected Output

```text
$ oc --context security-ws get pods -n acs-workshop
NAME                               READY   STATUS    RESTARTS   AGE
legacy-frontend-xxxxxxxxxx-xxxxx   1/1     Running   0          60s
node-agent-xxxxxxxxxx-xxxxx        1/1     Running   0          60s
payments-api-xxxxxxxxxx-xxxxx      1/1     Running   0          60s

$ curl -sI https://legacy-frontend-acs-workshop.apps.<cluster-domain> | head -3
HTTP/1.1 200 OK
server: nginx/1.14.0
...
```

`roxctl deployment check` already lists violations of **default** RHACS policies, for example
*Fixable Severity at least Important*, *Environment Variable Contains Secret*, *Privileged
Container*, and *Log4Shell: log4j Remote Code Execution vulnerability*. Enforcement is not enabled on
these policies yet, so every workload runs. That is the starting state for the next steps.

In the portal, **Violations** shows new alerts for the `acs-workshop` namespace.

## Why These Workloads Are Risky

- **Old base images build up CVEs over time.** Nothing in the NGINX 1.14 or UBI 8.0 image changed,
  yet new CVEs keep being published against the packages inside them. Scanning only at build time
  misses this. RHACS keeps re-matching running images against current vulnerability data.
- **Severity alone does not show risk.** A critical CVE in a privileged, internet-exposed pod is far
  more urgent than the same CVE in an isolated batch job. Step 4 shows how RHACS combines both.
- See [Examining images for vulnerabilities](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/examine-images-for-vulnerabilities)
  and [Default security policies](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/using-policies-to-provide-security).

## Official Documentation

- [Managing Security Context Constraints (OpenShift 4.19)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/managing-pod-security-policies)
- [Understanding and managing pod security admission (OpenShift 4.19)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/understanding-and-managing-pod-security-admission)
- [Route configuration (OpenShift 4.19)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/ingress_and_load_balancing/routes)

## Clean Up

This removes the workshop application, so you can deploy it again from scratch.

> **Warning:** If you have already completed [step 5](../05-policy-enforcement/), its policies block
> re-deploying these vulnerable workloads. Run the clean-up of the later steps first, in reverse
> order (07 → 03).

```bash
oc --context security-ws delete project acs-workshop --ignore-not-found
oc --context security-ws wait --for=delete namespace/acs-workshop --timeout=5m
```

The namespace deletion also removes the ServiceAccounts, the `anyuid` and `privileged`
RoleBindings, the Services, and the Route. RHACS removes the deployments from **Risk** and resolves
their deploy-time violations automatically. Runtime violations (from step 4) stay in **Violations**
until you resolve them. They do not affect a re-run.

Check before re-running:

```bash
oc --context security-ws get ns acs-workshop 2>&1 | grep -c NotFound      # expected: 1
```

## Next

Continue with [`03-vulnerability-management/`](../03-vulnerability-management/).
