# Recover a persistent singleton after a host failure

[The HA profile](high-availability.md) gives application and datastore replicas
separate hosts. Services that retain one writer, such as GitLab Omnibus and
SonarQube Community, instead need their process and Longhorn volume to restart
on a surviving host. A network partition is not proof that the old writer has
stopped. Storage replication alone cannot authorize that recovery.

The optional fencing job powers off an explicitly inventoried host through its
Redfish management controller, verifies the result, then applies Kubernetes'
`node.kubernetes.io/out-of-service:NoExecute` taint. Kubernetes can then remove
stranded pods and detach their volumes. This follows the
[Kubernetes non-graceful shutdown procedure](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/#non-graceful-node-shutdown).
The job does not delete nodes, force-delete pods, remove the taint, or restart a
host. Singleton recovery includes an outage; it does not supply active replicas.

## Requirements

Use this only after establishing the three-or-more-control-plane HA topology,
healthy Longhorn copies on separate hosts, and enough surviving workload
capacity. Every host eligible to run a persistent singleton needs a supported
management controller for automatic recovery from its failure.

The supported provider is a Redfish ComputerSystem endpoint with a stable UUID,
HTTPS with a trusted CA, explicit `ForceOff` support, and a reliable `PowerState`
property. BMC addresses must remain reachable from surviving control planes
through a management network when the node's normal network fails. Use a
separate account restricted to reading that ComputerSystem and powering it off.
The hardware UUID reported by Kubernetes must match Redfish. Unsupported
providers, ambiguous hardware identities, and inaccessible BMCs require manual
recovery; an OVHcloud account or ordinary SSH access is not a Redfish endpoint.

Disable automatic power-on policies, watchdog reboots and competing power
controllers for fenced hosts. A host must remain off until an operator finishes
recovery. The job verifies the off state immediately before the recovery taint,
but cannot lock out a separate actor that later powers the machine on.

## Prepare control-plane storage safety

Kubernetes normally permits timeout-based forced detach. Disable that path on
all control planes before allowing fencing to govern recovery. From a registered
control plane with private SSH access to all the others:

```bash
HIGH_AVAILABILITY_ENABLED=true bash scripts/configure-ha-control-planes.sh \
  --reconcile --node-network-cidr 10.40.0.0/24 \
  --control-plane-ip 10.40.0.10 --ssh-user admin
```

Use your actual private CIDR, source address and SSH account; `--ssh-port` and
`--identity-file` are also supported. Run one reconciliation at a time. The
helper adds `/etc/rancher/k3s/config.yaml.d/99-bm-ha-storage-safety.yaml` with
`kube-controller-manager-arg+: [disable-force-detach-on-timeout=true]`. It rejects
custom configuration locations or conflicting controller arguments. Other K3s
arguments remain intact.

Controllers restart sequentially only when their running policy is not already
verified and the managed drop-in is newer than the running K3s invocation. Missing
verification logs with an unchanged configuration require operator review. Each
restart requires a fresh Ready majority to survive, then a new
Ready heartbeat before moving on. Membership and private host identities are
checked throughout. The current K3s invocation's startup log must confirm the
flag before the helper marks the node's
`node.bm-cluster.io/fenced-detach-policy` annotation as `verified`.

The installer and Ansible reconciliation use the same helper. Additional control
planes in an existing HA cluster receive the drop-in before K3s starts. A local
join uses `HIGH_AVAILABILITY_ENABLED=true` explicitly; complete the fleet
reconciliation from an existing control plane afterward. Keep Longhorn's
`node-down-pod-deletion-policy` at `do-nothing`. Do not run separate automation
that forces volume detach or pod deletion before physical fencing.

## Enable an explicit inventory

Keep BMC credentials and cluster identities in a private directory outside Git.
Create `inventory.json` with this structure, replacing every example value:

```json
{
  "version": 1,
  "controlPlanes": {
    "cp-01": "00000000-0000-0000-0000-000000000001",
    "cp-02": "00000000-0000-0000-0000-000000000002",
    "cp-03": "00000000-0000-0000-0000-000000000003"
  },
  "nodes": [
    {
      "name": "cp-01",
      "nodeUID": "00000000-0000-0000-0000-000000000001",
      "systemUUID": "10000000-0000-0000-0000-000000000001",
      "computerSystemURL": "https://bmc-01.example.internal/redfish/v1/Systems/1",
      "username": "fencing",
      "password": "REPLACE_IN_PRIVATE_FILE",
      "caFile": "bmc-ca.pem"
    }
  ]
}
```

`controlPlanes` must contain the exact registered odd membership, including
Kubernetes node UIDs. `nodes` contains only the permitted fencing targets; add an
entry for each covered host. UIDs and hardware identities are available through
`kubectl get nodes -o json`. Place the CA certificate beside the inventory under
its `caFile` name. Restrict the directory to its owner and credential files to
mode `0600`. Never place credentials in Helm values or command arguments.

Check the local inventory against Kubernetes without contacting a BMC:

```bash
python3 k8s/scripts/fence-unresponsive-nodes.py --check-inventory \
  --inventory /private/fencing/inventory.json --allowed-nodes cp-01
```

This validates the inventory and current identities. It does not establish BMC
connectivity or permission to power off a host; verify those separately through
the hardware vendor's management interface during setup.

Create the mounted Secret without printing its contents:

```bash
kubectl -n infra create secret generic node-fencing-inventory \
  --from-file=inventory.json=/private/fencing/inventory.json \
  --from-file=bmc-ca.pem=/private/fencing/bmc-ca.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

Add this nonsecret map to the reviewed `PLATFORM_HA_VALUES_FILE` used by the
[HA activation workflow](high-availability.md):

```yaml
nodeFencing:
  enabled: true
  inventorySecret: node-fencing-inventory
  nodeNames: [cp-01]
```

The allowlist must exactly match the inventory; the example covers only one
host. RBAC permits node patches only for these names. The Secret is mounted as
a volume; the job has no API permission to read arbitrary Secrets. The job is
created only when both the global HA profile and fencing are enabled.

Adding or replacing control planes changes the pinned membership, so fencing
pauses until the Secret is deliberately refreshed with the new name/UID set.
A replaced target also requires its new Kubernetes UID and verified hardware
UUID. This prevents old configuration from acting on a different machine.

## Failure handling and return to service

The job checks once a minute and acts on at most one host per run. A candidate
must have both a non-Ready condition and a matching stale node Lease for at
least five minutes. A majority of the pinned control planes must remain Ready
with Lease renewals less than a minute old. It rechecks membership, quorum and
target identity before and after power-off. HTTPS redirects, untrusted
certificates, unexpected reset URLs and unconfirmed power state stop recovery.
The only power action is [Redfish `ForceOff`](https://www.dmtf.org/sites/default/files/standards/documents/DSP0268_2024.4.html).
Requests and jobs have time limits; failures stop without falling back to an
unsafe detach. A repeated run skips a node already tainted out of service.

Inspect `kubectl -n infra logs job/<node-fencing-job>` and the target's node
taints. After confirmed fencing, check that the replacement pod and volume are
healthy and that the service works. A failed run may have successfully powered
off the host but stopped before applying the taint; verify physical state and
read the failure before taking further action.

Returning the host requires an operator: identify the hardware fault or network
partition, confirm the old workload no longer owns any volume, and recover the
host while retaining its out-of-service taint. Remove that taint only after the
node, storage attachments and applications are healthy:

```bash
kubectl taint node cp-01 node.kubernetes.io/out-of-service:NoExecute-
```

Without a supported BMC, keep automatic fencing disabled. Independently confirm
that the failed host is powered off and cannot restart before manually following
the Kubernetes non-graceful shutdown procedure. A NotReady node or failed SSH
probe alone is insufficient evidence.
