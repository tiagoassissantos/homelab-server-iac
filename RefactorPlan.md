# Scope & Goals

**Scope (now):** create/reshape only **home-server-iac** so it can bootstrap a fresh server into a working k3s platform with ingress, storage, registry (TLS), monitoring, and **Argo Workflows (install only)**.

**Goals (Definition of Done)**

* Clean Ansible layout (roles-first, per-env inventories, secrets encrypted).
* Idempotent bootstrap of: k3s → MetalLB → Ingress (Traefik or NGINX) → cert-manager → Registry (TLS) → StorageClass → Metrics → Argo Workflows (vanilla).
* Simple, tagged runs + basic CI.
* Produce **outputs** (kubeconfig path, registry URL, default SC, ingress class, issuer, argo namespace) for other repos to consume later.

> 📝 **Later (when we work on `iac-garage-genie`)**: move any app-irrelevant, cluster-wide bits out of it. Do **not** remove or modify anything there now.

---

# Phase 0 — Safety, branch, assumptions

* Create branch: `feat/platform-bootstrap`.
* Assumptions: fresh hosts (no k3s yet), you can SSH as a sudoer.
* Keep your current kubeconfig (if any) separate; this plan will generate a new cluster.

---

# Phase 1 — Repo skeleton

```
home-server-iac/
├─ ansible.cfg
├─ requirements.yml
├─ .pre-commit-config.yaml
├─ Makefile
├─ outputs/                    # generated env outputs (JSON) go here
├─ inventories/
│  ├─ prod/
│  │  ├─ hosts.ini
│  │  └─ group_vars/
│  │     ├─ all.yml
│  │     └─ vault.yml          # 🔐 encrypt this
│  └─ staging/...
├─ playbooks/
│  ├─ site.yml
│  ├─ platform.yml             # bootstrap & addons (tagged)
│  └─ checks.yml               # post-deploy validations
└─ roles/
   ├─ host_base/               # OS prep (swap, time sync, pkgs)
   ├─ k3s/
   ├─ metallb/
   ├─ ingress/                 # traefik (default) or nginx
   ├─ cert_manager/
   ├─ registry/
   ├─ storage_class/           # local-path (default) or longhorn
   ├─ monitoring/              # metrics-server, optional extras
   ├─ argo_workflows_install/  # install only
   └─ outputs/                 # write cluster facts for consumers
```

**ansible.cfg**

```ini
[defaults]
inventory = inventories/prod/hosts.ini
forks = 20
host_key_checking = False
roles_path = roles
collections_paths = ./.ansible/collections:~/.ansible/collections
retry_files_enabled = False
stdout_callback = yaml
interpreter_python = auto_silent
```

**requirements.yml**

```yaml
collections:
  - name: community.general
  - name: ansible.posix
  - name: kubernetes.core
  - name: community.kubernetes
```

**.pre-commit-config.yaml**

```yaml
repos:
  - repo: https://github.com/ansible/ansible-lint
    rev: v24.7.0
    hooks: [ { id: ansible-lint } ]
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks: [ { id: yamllint } ]
```

**Makefile**

```make
install:
\tansible-galaxy install -r requirements.yml

lint:
\tansible-lint

syntax:
\tansible-playbook -i inventories/prod/hosts.ini playbooks/site.yml --syntax-check

bootstrap:
\tansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml --tags host_base,k3s,metallb,ingress,cert_manager,registry,storage

addons:
\tansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml --tags monitoring,argo,outputs

checks:
\tansible-playbook -i inventories/prod/hosts.ini playbooks/checks.yml
```

---

# Phase 2 — Inventories & secrets

**inventories/prod/hosts.ini**

```ini
[masters]
k3s-master-1 ansible_host=10.0.0.10

[workers]
# k3s-worker-1 ansible_host=10.0.0.11

[k3s:children]
masters
workers
```

**inventories/prod/group\_vars/all.yml** (non-secret, edit to your LAN)

```yaml
cluster_name: "home-k3s"
kubeconfig_path: "/etc/rancher/k3s/k3s.yaml"

# OS/base
timezone: "America/Sao_Paulo"
disable_swap: true

# Ingress (choose one)
ingress_controller: "traefik"  # or "nginx"

# MetalLB
metallb:
  address_pools:
    - name: default
      cidr: ["10.0.0.240/28"]  # adjust to your LAN

# DNS/Domain for ingress
dns:
  domain: "home.lab"           # e.g., app.home.lab

# cert-manager
cert_manager:
  issuer_kind: "ClusterIssuer"
  issuer_name: "home-ca"       # selfsigned or letsencrypt later

# Registry
registry:
  host: "10.0.0.10"
  port: 32522
  tls: true
  ingress:
    enabled: true              # false -> NodePort only
    host: "registry.home.lab"  # if ingress enabled
    class: "traefik"           # or nginx

# Storage
default_storage_class: "local-path"  # or "longhorn"

# Argo Workflows
argo:
  namespace: "argo"
  server_ingress_host: "argo.home.lab"
  ingress_class: "traefik"
```

**inventories/prod/group\_vars/vault.yml** (encrypt this file)

```yaml
vault_registry:
  username: "registry_user"
  password: "registry_pass"

# Only if using a custom CA (self-signed for internal TLS)
tls_ca:
  crt: |-
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  key: |-
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
```

Encrypt: `ansible-vault encrypt inventories/prod/group_vars/vault.yml`

> ✅ We are not touching other repos’ secrets now.

---

# Phase 3 — Playbooks wiring

**playbooks/site.yml**

```yaml
- import_playbook: platform.yml
- import_playbook: checks.yml
```

**playbooks/platform.yml**

```yaml
- name: Host base prep
  hosts: all
  become: true
  roles:
    - { role: host_base, tags: ["host_base"] }

- name: Bootstrap k3s cluster
  hosts: k3s
  become: true
  roles:
    - { role: k3s, tags: ["k3s"] }

- name: Cluster add-ons (run on master)
  hosts: masters
  become: true
  vars:
    kubeconfig_path: "{{ kubeconfig_path }}"
  roles:
    - { role: metallb,               tags: ["metallb"] }
    - { role: ingress,               tags: ["ingress"] }
    - { role: cert_manager,          tags: ["cert_manager"] }
    - { role: registry,              tags: ["registry"] }
    - { role: storage_class,         tags: ["storage"] }
    - { role: monitoring,            tags: ["monitoring"] }
    - { role: argo_workflows_install,tags: ["argo"] }
    - { role: outputs,               tags: ["outputs"] }
```

**playbooks/checks.yml** (light sanity)

```yaml
- name: Validate cluster
  hosts: masters
  gather_facts: false
  tasks:
    - name: Nodes Ready
      kubernetes.core.k8s_info:
        kind: Node
        kubeconfig: "{{ kubeconfig_path }}"
      register: nodes
    - assert:
        that: >
          {{ nodes.resources | selectattr('status.conditions','defined')
             | selectattr('status.conditions','selectattr','type','equalto','Ready')
             | map(attribute='status.conditions') | flatten
             | selectattr('type','equalto','Ready')
             | selectattr('status','equalto','True') | list | length >= 1 }}

    - name: Default StorageClass present
      kubernetes.core.k8s_info:
        api_version: storage.k8s.io/v1
        kind: StorageClass
        kubeconfig: "{{ kubeconfig_path }}"
      register: sc
    - assert:
        that: "{{ sc.resources | selectattr('metadata.annotations.\"storageclass.kubernetes.io/is-default-class\"','equalto','true') | list | length == 1 }}"
```

---

# Phase 4 — Role responsibilities (what each must do)

### `host_base`

* Ensure timezone, swap off (if chosen), kernel params for containers if needed, `chrony`/`ntp`, and base packages (`curl`, `tar`, `iptables` if required).
* Detect distro and install deps accordingly (keep tasks OS-agnostic via `ansible_facts`).

### `k3s`

* Install k3s on master(s) and worker(s), pin version (var), configure token/join.
* Optionally disable built-in Traefik if you plan to use NGINX (`--disable traefik`).
* Ensure kubeconfig at `{{ kubeconfig_path }}` readable for subsequent roles.

### `metallb`

* Install via Helm/manifests.
* Create `IPAddressPool` and `L2Advertisement` from `metallb.address_pools`.

### `ingress`

* If `traefik`: ensure CRDs/Helm values tuned; set `ingressClassName: traefik`.
* If `nginx`: install via Helm; optionally disable Traefik in `k3s` role.
* (No app routes yet; only platform endpoints we define below.)

### `cert_manager`

* Install cert-manager via Helm.
* Create `ClusterIssuer`:

  * **Self-signed CA** for internal TLS (store CA in `tls_ca` or have cert-manager generate it).
  * Later you can switch to Let’s Encrypt if you expose services publicly.

### `registry`

* Deploy a **secure internal registry** (Deployment + PVC + Service).
* Auth (BasicAuth from `vault_registry`).
* **TLS**:

  * If `registry.ingress.enabled: true`: create Ingress (`registry.home.lab`) annotated for cert-manager to issue a cert.
  * Else: expose NodePort/LoadBalancer with a TLS secret; ensure clients trust the CA (documented in outputs).
* Result: reachable at `https://registry.home.lab` **or** `https://10.0.0.10:32522`.

### `storage_class`

* Install/set default StorageClass:

  * `local-path` (simple) or Longhorn (if you want replicated/HA volumes).

### `monitoring`

* Install `metrics-server` (needed for HPA).
* (Optional) kube-state-metrics/node-exporter for future Grafana/Prometheus.

### `argo_workflows_install`

* Install **Argo Workflows** (CRDs, controller, server) via Helm to `{{ argo.namespace }}`.
* Optional Ingress for Argo Server at `argo.home.lab` (authn method up to you).
* **No WorkflowTemplates here** (those are app-scoped and will stay for later in `iac-garage-genie`).

### `outputs`

* Gather and **write** a machine-readable file for other repos to use later, e.g.:

  * `./outputs/prod.json` (created with `delegate_to: localhost`)

```json
{
  "cluster_name": "home-k3s",
  "kubeconfig_path": "/etc/rancher/k3s/k3s.yaml",
  "default_storage_class": "local-path",
  "ingress_class": "traefik",
  "domain": "home.lab",
  "registry": {
    "url": "https://registry.home.lab",
    "host": "10.0.0.10",
    "port": 32522,
    "tls": true
  },
  "cert_manager": {
    "issuer_kind": "ClusterIssuer",
    "issuer_name": "home-ca"
  },
  "argo": {
    "namespace": "argo",
    "server_host": "argo.home.lab"
  }
}
```

> 📝 **Later (when we work on `iac-garage-genie`)**: we will make that repo **read** these outputs for its config (namespace, issuer name, ingress class, registry URL), and only then remove any duplicates there. **Do not delete anything there now.**

---

# Phase 5 — CI (home-server-iac only)

`.github/workflows/ci.yml`

```yaml
name: Ansible CI
on: { push: { branches: ["main","feat/**"] }, pull_request: {} }
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: |
          python -m pip install --upgrade pip
          pip install ansible ansible-lint yamllint
          ansible-galaxy install -r requirements.yml
      - run: yamllint .
      - run: ansible-lint
      - run: ansible-playbook -i inventories/prod/hosts.ini playbooks/site.yml --syntax-check
```

---

# Phase 6 — From-scratch run order

1. `make install`
2. `make lint syntax`
3. **Bootstrap the platform:**
   `make bootstrap`
   (runs: host\_base, k3s, metallb, ingress, cert\_manager, registry, storage)
4. **Addons & outputs:**
   `make addons`
   (runs: monitoring, argo, outputs)
5. **Sanity checks:**
   `make checks`

**Manual spot-checks (examples)**

* `kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes`
* `kubectl get sc` → default is `local-path` (or your choice).
* `kubectl -n argo get deploy` → controller/server Ready.
* If registry via Ingress: browse `https://registry.home.lab` (expect TLS).
* If NodePort: `docker login 10.0.0.10:32522` with `vault_registry` creds.

---

# Phase 7 — Documentation (home-server-iac only)

* `README.md`: quickstart (prereqs, make targets, inventory vars).
* `docs/runbook.md`: rotate certs, change MetalLB pool, upgrade k3s.
* `docs/outputs.md`: define the **contract** other repos can rely on (point them to `outputs/prod.json`).

> 📝 **Later (when we work on `iac-garage-genie`)**
>
> * Read `outputs/prod.json` (or the same values) to configure:
>
>   * `ingressClassName`, `ClusterIssuer`, `registry URL`, `default SC` (if needed), `argo namespace`.
> * Migrate any platform-scope tasks from there **into** home-server-iac at that time.
> * Only then clean up duplicates in `iac-garage-genie`.
> * `garage-genie` (Rails) stays unchanged for now.

---

## Quick win checklist (this repo only)

* [ ] Skeleton + configs committed
* [ ] Prod inventory split (`all.yml` vs encrypted `vault.yml`)
* [ ] `host_base` prepared (swap/time sync/pkgs)
* [ ] k3s installed & kubeconfig path set
* [ ] MetalLB pool applied; LB services will get IPs
* [ ] Ingress controller ready (Traefik or NGINX)
* [ ] cert-manager + ClusterIssuer working
* [ ] Internal registry up (auth + TLS)
* [ ] Default StorageClass set
* [ ] metrics-server installed
* [ ] Argo Workflows installed (no app templates)
* [ ] `outputs/prod.json` generated
* [ ] CI green (lint + syntax)

---

If you want, I can next **draft empty role skeletons** (`tasks/main.yml`, `defaults/main.yml`, `templates/*`) for each role above so you can paste them in and start filling the specifics.
