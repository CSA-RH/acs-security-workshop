# Step 4 — Risk Analysis: Prioritize by Real Exposure

## Summary

A CVE list tells you what is *vulnerable*. It does not tell you what is *dangerous*. In this step you
use the RHACS **Risk** view, which ranks every deployment with a multi-factor score. The score
combines image vulnerabilities, policy violations, service configuration (privileges, capabilities,
read-write filesystem), network reachability, RBAC permissions, image age, and runtime behavior. You
create some suspicious runtime activity, watch it change the ranking, trace real network flows in the
**Network Graph**, and write a short prioritized remediation plan. Steps 5 and 6 carry out that plan.

## Prerequisites

- [Step 3](../03-vulnerability-management/) completed
- `oc` access to namespace `acs-workshop`

> No YAML in this step. It is about analysis and runtime observation.

## Steps

### Part A — Read the Risk ranking

1. In the RHACS portal, open **Risk** and filter by **Namespace: `acs-workshop`**.
2. Compare the **Priority** column with the CVE counts from step 3. `legacy-frontend` has by far the
   most CVEs. Look at where `node-agent` and `payments-api` rank against it, and think about why.
3. Open `node-agent` → **Risk indicators**. Expect to see:
   - **Service Configurations**: *privileged* container, capabilities not dropped, read-write root filesystem
   - **RBAC Configuration**: the ServiceAccount can use the `privileged` SCC
   - **Image Freshness**: the image is several years old
   - **Policy Violations**: *Privileged Container*, *Fixable Severity at least Important*, and others
4. Open `legacy-frontend` → **Risk indicators**. Expect:
   - **Service Reachability**: port exposed **outside the cluster** (Route)
   - **Policy Violations**: *Environment Variable Contains Secret*, *Container using read-write root filesystem*, and others
   - **Image Vulnerabilities**: a very high CVE count
   - **Components Useful for Attackers**: package managers and shells that are present in the image
5. Open `payments-api` → **Risk indicators**. Note that Log4Shell (CVSS 10.0) is on the Deferred list
   from step 3. The deployment is still at risk, because its image has other fixable, high-severity
   CVEs.

### Part B — Runtime signals change risk

6. Simulate what an attacker does after getting in: open a shell, run a package manager, and read a
   host file through the privileged agent:
   ```bash
   oc --context security-ws exec -n acs-workshop deploy/legacy-frontend -- apt-get -v
   oc --context security-ws exec -n acs-workshop deploy/legacy-frontend -- sh -c 'id; cat /etc/passwd | head -3'
   oc --context security-ws exec -n acs-workshop deploy/node-agent -- sh -c 'cat /host/etc/hostname; ls /host/var/lib/kubelet | head -3'
   ```
7. Wait about 1 minute, then check:
   - **Violations**: new runtime alerts such as *Ubuntu Package Manager Execution* and *Kubernetes
     Actions: Exec into Pod*
   - **Risk → legacy-frontend → Process discovery**: `apt-get`, `sh`, `id`, and `cat` appear in the
     event timeline, outside the deployment's normal process baseline
   - The **Priority** of the affected deployments goes up. Runtime evidence adds to the risk score.
8. Optional: on the **Process discovery** tab, **lock** the process baseline of `legacy-frontend`.
   Any process outside the baseline now raises a violation.

### Part C — Look at network exposure

9. Open **Network → Network Graph** and select cluster `workshop-cluster`, namespace `acs-workshop`.
10. Click `legacy-frontend` and check **Flows**. Ingress comes from the OpenShift router (external
    entities). No NetworkPolicy exists, so the graph marks every deployment as allowing **all
    ingress and egress**.
11. Click `payments-api` → **Flows / Baseline**. Log4Shell needs **outbound** connections (LDAP or
    RMI callbacks) to deliver a payload. Without egress controls, nothing blocks that callback.

### Part D — Write the remediation plan

12. Use what you found to fill in a plan like this one. Steps 5 and 6 implement it.

| Priority | Deployment | Main risk | Action | Step |
|---|---|---|---|---|
| 1 | `node-agent` | Privileged plus host access means container escape equals node compromise | Remove privilege and host mounts, rebase on a current UBI 9 image | 05 (block) and 06 (fix) |
| 2 | `legacy-frontend` | Internet-facing, root, plaintext secret, hundreds of CVEs | Rebase on a supported Red Hat NGINX image, non-root, secret from a `Secret` | 05 and 06 |
| 3 | `payments-api` | Critical RCE with no patch available yet | Formal exception (done in 03), egress-deny NetworkPolicy as a compensating control, block new Log4Shell builds in CI | 05, 06, 07 |
| — | All | Nothing stops a new vulnerable deployment | Policy-as-code guardrails with admission enforcement | 05 |

## Expected Output

```text
Risk (namespace: acs-workshop)          Priority
------------------------------------    --------
node-agent                              1
legacy-frontend                         2
payments-api                            3
```

The exact priority numbers are global across the cluster and depend on what else is running. What
matters is the *relative* order: `node-agent` often outranks `legacy-frontend` despite having far
fewer CVEs. **Violations** now lists runtime alerts for the `oc exec` activity, and the network
graph shows `acs-workshop` without any NetworkPolicy.

## Official Documentation

- [Evaluating security risks (Risk view, risk indicators, process baselines)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/evaluate-security-risks)
- [Responding to violations](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/respond-to-violations)
- [Managing network policies (Network Graph)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/manage-network-policies)
- [Default security policies reference](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/operating/using-policies-to-provide-security)

## Next

Continue with [`05-policy-enforcement/`](../05-policy-enforcement/).
