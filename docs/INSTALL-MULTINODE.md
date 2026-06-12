# Multi-node install + validation (M-NODE)

True multi-node: several GPU boxes joined into ONE vGPU cluster — the scheduler
spreads slices across nodes, gangs commit atomically across machines, and a
lost node's capacity vanishes from scheduling immediately.

Networking: k3s with the **wireguard-native** flannel backend, which works
between cloud instances over public IPs. Between nodes you need **TCP 6443**
(join + API) and **UDP 51820** (WireGuard) reachable — on Lambda, instances in
the same region reach each other directly.

## What to buy

| Goal | Instances | ~Cost |
|---|---|---|
| Multi-GPU-per-node (M-GPU) | 1× `8×A100` box | ~$10–14/hr, ~1 hr |
| Multi-node (M-NODE) | 2–3× `1×A100` boxes | ~$1.3/hr each, ~1 hr |

The two validations are independent — run them **in parallel** in separate
terminals.

## Multi-node, step by step

**Node 1 (the server):**
```sh
git clone git@github.com:pranav2910/vgpu_scheduler.git && cd vgpu_scheduler
bash scripts/multinode-server.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```
It ends by printing `K3S_URL` + `K3S_TOKEN` + the agent command.

**Every other node:**
```sh
git clone git@github.com:pranav2910/vgpu_scheduler.git && cd vgpu_scheduler
export K3S_URL="https://<server-ip>:6443"
export K3S_TOKEN="<token from the server>"
bash scripts/multinode-agent.sh
```
Each agent ends by printing a **capacity one-liner to run on the server**
(agents have no API access). Run it, then check `kubectl get nodes` shows
every node Ready and `kubectl get pods -n vgpu-system -o wide` shows a
node-agent pod per node.

**Validate (on the server):**
```sh
bash scripts/validate-multinode.sh              # T1–T4
bash scripts/validate-multinode.sh --node-loss  # adds T5 (deletes a node object)
```

| Test | Proves |
|---|---|
| T1 spread | grants exceeding one node land on **every** node, all Ready |
| T2 node-fit | a grant bigger than ANY node stays Pending — never mis-binds |
| T3 cross-node gang | a gang too big for one machine commits **all-or-nothing across nodes** |
| T4 topology | zone preference honored with the auditable condition |
| T5 node loss | node deleted from the API → capacity gone, new work lands on survivors |

After `--node-loss`, re-join the deleted node with
`sudo systemctl restart k3s-agent` on that box (or just tear everything down).

## The parallel session plan (testing M-GPU and M-NODE at once)

- **Terminal A** → 8×A100 box: `h100-control-plane.sh` →
  `validate-multigpu-a100.sh` (see its header for what it asserts).
- **Terminals B/C** → the 1×A100 boxes: server script on B, agent script on C,
  advertise one-liner back on B, then `validate-multinode.sh --node-loss`.

Both green ⇒ tag `v0.14` and the two honest limits — "single GPU per node" and
"single node" — come off the one-pager.

## Honest scope

- The scheduler pools capacity per node; per-card fit is enforced by the node
  agent's best-fit allocator, and an unsatisfiable grant **fails loud**
  ("Fragmented capacity") rather than over-packing a card.
- WireGuard adds ~µs-scale overlay latency — irrelevant for control traffic;
  workload data never crosses the overlay (pods use their local GPU).
- Multi-GPU **pods** (one pod spanning several cards) and NVLink-aware
  placement are out of scope this milestone.
