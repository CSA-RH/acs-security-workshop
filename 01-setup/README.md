# Step 1 — Setup: Install RHACS 4.11

## Description

In this step you install Red Hat Advanced Cluster Security for Kubernetes (RHACS) 4.11 on a clean
OpenShift cluster through the RHACS Operator. You deploy **Central** (the management plane, with
Scanner V4), register the same cluster as a **secured cluster** with a cluster registration secret
(CRS), and deploy Sensor, Collector, and the Admission Controller. At the end you have a working
RHACS portal and an authenticated `roxctl` CLI, which every later step uses.

## Prerequisites

- OpenShift Container Platform 4.19 or later (a fresh install is fine)
- `oc` CLI logged in as a user with `cluster-admin`, with the kubeconfig context named `security-ws` (see the [top-level Quick Start](../README.md#quick-start))
- `jq` and `curl` on your workstation
- Outbound internet access from the cluster (to `registry.redhat.io` and to the vulnerability feeds Scanner V4 downloads)
- At least 2 worker nodes (tested on ROSA HCP with 2 workers). `04-central.yaml` is sized for this footprint.
- Sizing guidance: [Default resource requirements for RHACS](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/installing/acs-default-requirements)

## Files

| File | Role |
|---|---|
| `01-namespaces.yaml` | `rhacs-operator` and `stackrox` namespaces |
| `02-operatorgroup.yaml` | All-namespaces OperatorGroup for the RHACS Operator |
| `03-subscription.yaml` | OLM Subscription to `rhacs-operator` (`stable` channel) |
| `04-central.yaml` | `Central` CR: Central, Central DB, Scanner V4 (legacy StackRox Scanner disabled), and a Route. Explicit resources and single-replica scanners for small clusters. |
| `05-secured-cluster.yaml` | `SecuredCluster` CR: Sensor, Collector, Admission Controller (with enforcement) |

## Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/demon86rm/acs-security-workshop.git
   cd acs-security-workshop/01-setup
   ```

2. Install the RHACS Operator:
   ```bash
   oc --context security-ws apply -f 01-namespaces.yaml -f 02-operatorgroup.yaml -f 03-subscription.yaml
   ```

3. Wait for the Operator CSV to reach `Succeeded`, then check that it is a 4.11.x version:
   ```bash
   oc --context security-ws get csv -n rhacs-operator -w
   ```

4. Deploy Central, then wait for it. Scanner V4 needs a few extra minutes to load vulnerability data.
   ```bash
   oc --context security-ws apply -f 04-central.yaml
   oc --context security-ws wait central/stackrox-central-services -n stackrox \
     --for=condition=Deployed --timeout=15m
   oc --context security-ws get pods -n stackrox
   ```

5. Get the portal URL and the generated `admin` password, then create an API token for `roxctl`:
   ```bash
   export ROX_ENDPOINT="$(oc --context security-ws get route central -n stackrox -o jsonpath='{.spec.host}'):443"
   export ROX_ADMIN_PASSWORD="$(oc --context security-ws get secret central-htpasswd -n stackrox \
     -o go-template='{{index .data "password" | base64decode}}')"

   export ROX_API_TOKEN="$(curl -sk -u "admin:${ROX_ADMIN_PASSWORD}" \
     "https://${ROX_ENDPOINT}/v1/apitokens/generate" \
     -d '{"name":"workshop-admin","roles":["Admin"]}' | jq -r .token)"

   echo "Portal: https://${ROX_ENDPOINT%:443}   user: admin   password: ${ROX_ADMIN_PASSWORD}"
   ```
   `roxctl` reads `ROX_ENDPOINT` and `ROX_API_TOKEN` from the environment automatically. Keep this
   shell open, or save the exports to a file, for the rest of the workshop.

6. Install `roxctl` 4.11 (it must match the Central version):
   ```bash
   # Linux x86_64: .../bin/Linux/roxctl   macOS Intel: .../bin/Darwin/roxctl   macOS Apple silicon: .../bin/Darwin/roxctl-arm64
   curl -fLo roxctl https://mirror.openshift.com/pub/rhacs/assets/4.11.4/bin/Linux/roxctl
   chmod +x roxctl && sudo mv roxctl /usr/local/bin/
   roxctl version
   roxctl central whoami --insecure-skip-tls-verify
   ```

7. Generate a **cluster registration secret (CRS)** and apply it to the `stackrox` namespace:
   ```bash
   roxctl central crs generate workshop-cluster \
     --insecure-skip-tls-verify --output workshop-cluster-crs.yaml
   oc --context security-ws apply -n stackrox -f workshop-cluster-crs.yaml
   ```
   > The CRS file holds credentials. Do not commit it (it is listed in `.gitignore`).

8. Deploy the secured cluster services:
   ```bash
   oc --context security-ws apply -f 05-secured-cluster.yaml
   oc --context security-ws get pods -n stackrox -w
   ```

## Expected Output

```text
$ oc --context security-ws get csv -n rhacs-operator
NAME                     DISPLAY                                          VERSION   PHASE
rhacs-operator.v4.11.4   Advanced Cluster Security for Kubernetes         4.11.4    Succeeded

$ oc --context security-ws get pods -n stackrox
NAME                                  READY   STATUS    RESTARTS   AGE
admission-control-xxxxxxxxxx-xxxxx    1/1     Running   0          3m
central-xxxxxxxxxx-xxxxx              1/1     Running   0          12m
central-db-xxxxxxxxxx-xxxxx           1/1     Running   0          12m
collector-xxxxx                       3/3     Running   0          3m      # one per node
config-controller-xxxxxxxxxx-xxxxx    1/1     Running   0          12m
scanner-v4-db-xxxxxxxxxx-xxxxx        1/1     Running   0          12m
scanner-v4-indexer-xxxxxxxxxx-xxxxx   1/1     Running   0          12m
scanner-v4-matcher-xxxxxxxxxx-xxxxx   1/1     Running   0          12m
sensor-xxxxxxxxxx-xxxxx               1/1     Running   0          3m

$ roxctl central whoami --insecure-skip-tls-verify
UserID:
        auth-token:...
User name:
        workshop-admin
Roles:
        - Admin
```

In the portal, **Platform Configuration → Clusters** shows `workshop-cluster` with a **Healthy**
status for Sensor, Collector, Admission Controller, and Scanner.

> The `config-controller` pod reconciles `SecurityPolicy` custom resources (policy as code), which
> step 5 uses. It is enabled by default.

## Official Documentation

- [Installing RHACS on Red Hat OpenShift](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/installing/installing-rhacs-on-red-hat-openshift)
- [High-level installation overview (init bundles and cluster registration secrets)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/installing/acs-high-level-overview)
- [Installing the roxctl CLI](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/roxctl_cli/installing-the-roxctl-cli-1)
- [Configuring API tokens](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/configuring/configure-api-token)
- [RHACS 4.11 release notes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/release_notes/release-notes-411)
- [Installing Operators with OLM (OpenShift 4.19)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/operators/user-tasks)

## Next

Continue with [`02-deploy-vulnerable-workloads/`](../02-deploy-vulnerable-workloads/).
