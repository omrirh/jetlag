# Jetlag RHOAI/llm-d Disconnected BM — Open Tasks

## Jenkins External Cluster Visibility

**Goal:** Allow a remote Jenkins instance (with `oc` tooling) to reach the
disconnected cluster's API and app routes through the bastion's HAProxy.

**Approach:** HAProxy on the bastion already forwards `:6443`, `:443`, `:80`
from the bastion's public IP to the cluster. No bastion-side changes needed.
Jenkins needs a kubeconfig patched to the bastion FQDN + DNS resolution for
app routes via `/etc/hosts` injection.

### Bastion side

- [ ] Emit `cluster-info.env` at the end of `deploy.sh` step 6 containing:
  - `CLUSTER_API_URL=https://<bastion-fqdn>:6443`
  - `CLUSTER_APPS_DOMAIN=apps.mno.<base_dns_name>`
  - `BASTION_IP=<bastion-public-ip>`
  - `BASTION_FQDN=<bastion-fqdn>`
  - Path to cluster CA cert and kubeadmin password on the bastion
- [ ] Patch the kubeconfig written to `/root/mno/kubeconfig` so `server:`
  points to `https://<bastion-fqdn>:6443` instead of the internal cluster IP
  (allows Jenkins to consume it directly without further patching)

### Jenkins side

- [ ] Confirm Jenkins agents have sudo access (required for `/etc/hosts`
  injection)
- [ ] Add JobParams:
  - `KUBECONFIG` (secret file) — patched kubeconfig from bastion
  - `BASTION_IP` — bastion public IP for DNS injection
  - `CLUSTER_APPS_DOMAIN` — e.g. `apps.mno.rdu3.labs.perfscale.redhat.com`
- [ ] Add pipeline preamble step that injects cluster endpoints into
  `/etc/hosts` on the agent (`api.mno.<domain>` + all app routes → `BASTION_IP`).
  Routes enumerable via `oc get routes -A` or a static RHOAI-specific list.
- [ ] Decide on TLS strategy:
  - Option 1: embed cluster CA in kubeconfig (validates hostname correctly)
  - Option 2: `insecure-skip-tls-verify: true` (simpler for internal CI)
- [ ] Document final Jenkins param/preamble contract in
  `docs/deploy-mno-rhoai-disconnected.md`
