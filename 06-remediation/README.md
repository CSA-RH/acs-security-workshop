# Step 6 — Remediation and Risk Mitigation

## Summary

This step carries out the plan from step 4 and shows the difference between **remediation**
(removing the vulnerability) and **mitigation** (reducing its exploitability when it cannot be
removed yet):

| Deployment | Strategy | How |
|---|---|---|
| `legacy-frontend` | **Remediate** | Rebase from upstream `nginx:1.14.0` to the supported Red Hat `ubi9/nginx-124` image. Run as non-root under `restricted-v2`. Move the plaintext secret into a `Secret`. |
| `node-agent` | **Remediate** | Current `ubi9/ubi-minimal` base image. Remove privileged mode, host namespaces, and the host mount. Remove the SCC grant. |
| `payments-api` | **Mitigate** (compensating control) | No patched build exists. Apply a default-deny NetworkPolicy that blocks all egress, including DNS, so the Log4Shell JNDI callback cannot connect. Allow ingress only from the frontend. The CVE stays formally deferred (step 3) and excluded from enforcement (step 5) until a fixed image is available. |

The RHACS admission controller from step 5 checks each fix as it is applied: a fix passes only if it
really meets the policies. The Risk view, Violations, and the Network Graph then confirm that the
risk went down.

## Prerequisites

- [Step 5](../05-policy-enforcement/) completed. `legacy-frontend` and `node-agent` were scaled to 0 by RHACS.
- `cluster-admin` (to remove the SCC RoleBindings)
- OVN-Kubernetes network plugin (the default on OpenShift 4.19+) for NetworkPolicy support

## Files

| File | Role |
|---|---|
| `01-namespace-restricted.yaml` | Namespace back to Pod Security Admission `restricted` |
| `02-legacy-frontend-hardened.yaml` | Hardened frontend Deployment and Service (UBI 9 NGINX 1.24, non-root, secret from `Secret`) |
| `03-node-agent-hardened.yaml` | Hardened agent Deployment (UBI 9 minimal, no privileges, read-only root filesystem) |
| `04-network-policies.yaml` | Default deny plus the minimal allow rules. Serves as the Log4Shell compensating control. |

## Steps

1. Check the hardened manifests against RHACS **before** applying them:
   ```bash
   cd ../06-remediation
   roxctl deployment check --insecure-skip-tls-verify --cluster workshop-cluster \
     -f 02-legacy-frontend-hardened.yaml -f 03-node-agent-hardened.yaml --output table
   ```
   None of the workshop policies with enforcement (fixable Important CVEs, privileged) should show
   **BREAKS DEPLOY**.

2. Remove the excess privileges. RoleBindings are removed imperatively because a declarative
   `apply` does not delete objects:
   ```bash
   oc delete rolebinding legacy-frontend-anyuid node-agent-privileged -n acs-workshop
   ```

3. Put the database password into a `Secret`. It is generated at apply time and never stored in Git:
   ```bash
   oc create secret generic legacy-frontend-db -n acs-workshop \
     --from-literal=DB_PASSWORD="$(openssl rand -base64 18)"
   ```

4. Apply the remediation:
   ```bash
   oc apply -f 01-namespace-restricted.yaml
   oc apply -f 02-legacy-frontend-hardened.yaml -f 03-node-agent-hardened.yaml
   oc apply -f 04-network-policies.yaml
   oc get pods -n acs-workshop -w
   ```
   The admission controller admits these updates, including scaling back to 1 replica, because the
   new pod specs no longer violate the enforced policies.

5. Check the application and the compensating control:
   ```bash
   # Frontend is served again through the Route (by the Red Hat NGINX image, non-root)
   curl -sI "https://$(oc get route legacy-frontend -n acs-workshop -o jsonpath='{.spec.host}')" | head -3
   oc exec -n acs-workshop deploy/legacy-frontend -- id

   # payments-api can no longer resolve names or open outbound connections (Log4Shell callback path)
   oc exec -n acs-workshop deploy/payments-api -- sh -c 'wget -T 3 -qO- http://example.com >/dev/null && echo OPEN || echo BLOCKED'
   ```

6. Confirm in RHACS that the risk is lower. Allow 1–2 minutes for re-evaluation:
   - **Risk** (namespace `acs-workshop`): `node-agent` and `legacy-frontend` fall down the ranking.
     Their risk indicators no longer show privileged mode, root, external secrets in env vars, or
     old images.
   - **Violations**: the deploy-time violations for the old pod specs are **resolved**. Only
     `payments-api` still shows *Log4Shell* and *untrusted registry*, both inform-only.
   - **Vulnerability Management → Results** (namespace `acs-workshop`): the fixable
     Important/Critical CVE count drops by more than an order of magnitude.
   - **Network → Network Graph**: `acs-workshop` now shows NetworkPolicies. Select `payments-api`
     and check that egress is denied.

7. Optional: keep the risk acceptance honest. When a patched `payments-api` image is available (log4j
   ≥ 2.17.1), remove the `exclusions` block from
   [`../05-policy-enforcement/01-policy-fixable-important-cves.yaml`](../05-policy-enforcement/01-policy-fixable-important-cves.yaml),
   re-apply it, and withdraw the CVE deferral in **Exception Management**.

## Expected (Working) Output

```text
$ oc get pods -n acs-workshop
NAME                               READY   STATUS    RESTARTS   AGE
legacy-frontend-yyyyyyyyyy-yyyyy   1/1     Running   0          45s
node-agent-yyyyyyyyyy-yyyyy        1/1     Running   0          45s
payments-api-xxxxxxxxxx-xxxxx      1/1     Running   0          70m

$ curl -sI https://legacy-frontend-acs-workshop.apps.<cluster-domain> | head -3
HTTP/1.1 200 OK
server: nginx/1.24.x
...

$ oc exec -n acs-workshop deploy/legacy-frontend -- id
uid=1000xxxxxx(1000xxxxxx) gid=0(root) groups=0(root),1000xxxxxx

$ oc exec -n acs-workshop deploy/payments-api -- sh -c 'wget ... || echo BLOCKED'
wget: bad address 'example.com'
BLOCKED

$ oc get networkpolicy -n acs-workshop
NAME                         POD-SELECTOR          AGE
allow-frontend-egress        app=legacy-frontend   1m
allow-frontend-to-payments   app=payments-api      1m
allow-router-to-frontend     app=legacy-frontend   1m
default-deny-all             <none>                1m
```

> The `latest` Red Hat images are rebuilt often and usually have no fixable Important CVEs. If a new
> erratum is published between rebuilds, the admission controller correctly blocks the rollout. Pin
> to the newest digest in that case, or update the image when the rebuild ships. This is the
> guardrail doing its job.

## Official Documentation

- [Evaluating security risks (Risk view)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/evaluate-security-risks)
- [Managing network policies in RHACS (Network Graph, baselines, simulation)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/manage-network-policies)
- [Build-time network policy tools (`roxctl netpol generate`)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/build-time-network-policy-tools)
- [Managing vulnerabilities: exception workflow](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/managing-vulnerabilities)
- [Network policy (OpenShift 4.19)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/network_security/network-policy)
- [Managing Security Context Constraints (OpenShift 4.19)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/managing-pod-security-policies)
- [Understanding and managing pod security admission (OpenShift 4.19)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/authentication_and_authorization/understanding-and-managing-pod-security-admission)

## Alternatives Considered

| Approach | Notes |
|---|---|
| Hand-written NetworkPolicies (this step) | Exact and easy to review. Needs knowledge of the application's flows. |
| `roxctl netpol generate` from the manifests | RHACS generates least-privilege policies from the Deployment and Service YAML at build time. Useful for larger applications. Review the output before applying. |
| `AdminNetworkPolicy` / `BaselineAdminNetworkPolicy` | Cluster-scoped guardrails that tenants cannot override. Useful for platform-wide egress rules. |
| `EgressFirewall` (OVN-Kubernetes) | Namespace egress control by CIDR or DNS name. Useful when some outbound access must stay open. |
| Virtual patching with WAF or Service Mesh rules | Filters `${jndi:` payloads at the edge. Adds defense in depth but can be bypassed by obfuscation, so it should not be the only control. |

## Next

Continue with [`07-shift-left-ci-gate/`](../07-shift-left-ci-gate/).
