### Running the same Argo experiment on `urunc` (Linux guest, shared fs)

This is the same experiment as [`argo-runc`](../argo-runc), but the workflow pod uses the `urunc` RuntimeClass. The goal was to reproduce the hang from [urunc#135](https://github.com/urunc-dev/urunc/issues/135) (workflow stuck in `Running`, `wait` never exits) with stock urunc v0.8.0. Instead of a unikernel, `main` boots a Linux VM (QEMU) whose rootfs is the container rootfs shared over virtiofs.

Logging is the same as before:

1. `journalctl` for service logs (`-u kubelet`, `-u containerd`, `-t urunc`)
2. `kubectl logs` for container logs
3. `snap.sh` for snapshots (updated for urunc, see `scripts/snap.sh`)

**Result: no hang.** The workflow ended in `Error` after 3 min 20 s.

---

## Setup

Same host and cluster as `argo-runc` (kubeadm/kubelet/kubectl v1.37.0, containerd v2.4.0, runc v1.5.1, CNI v1.9.1, Flannel v0.28.9, Argo Workflows v4.1.4). On top of that:

- urunc v0.8.0 + `containerd-shim-urunc-v2` (release binaries)
- QEMU 10.1.1 and virtiofsd 1.13.0 in `/opt/urunc` (urunc monitors-build bundle)
- urunc config: `manifests/urunc-config.toml`
- containerd handler: `manifests/containerd-urunc-handler.toml` (overlayfs snapshotter), RuntimeClass: `manifests/runtimeclass.yaml`
- Guest kernel: Linux 6.12.36 with virtiofs, taken from `harbor.nbfc.io/nubificus/urunc/readfile-qemu-linux-raw@sha256:6a898c40a681bc81bddcd9abdbf49b39ef91ad3991bc0419aff7c049ad10ea59` (the prebuilt `linux-kernel-qemu:v6.14` has no virtiofs)
- Main image `docker.io/urunc-argo/python-linux-qemu:135`: `python:alpine3.23` + that kernel, built with bunny (`image/bunnyfile`)

`manifests/smoke.yaml` checks the image on its own before Argo: python runs as the guest's init and prints 42.

`experiment.yaml` keeps the same script. Only these lines changed:

```yaml
  podSpecPatch: '{"runtimeClassName":"urunc","enableServiceLinks":false}'
  ...
        image: docker.io/urunc-argo/python-linux-qemu:135
        imagePullPolicy: Never
```

`enableServiceLinks: false` keeps the env var count low. urunc v0.8.0 puts env vars on the guest kernel command line when the image command does not start with urunit, and the kernel accepts only about 30 of them.

`RUNLOG.md` lists every step, with its output in `logs/setup/` (the kubeadm join token is redacted).

---

## What I found

| Container | Image | Started | Completed | Duration | Exit code |
|-----------|-------|---------|-----------|---------:|-----------|
| init (urunc → runc) | `quay.io/argoproj/argoexec:v4.1.4` | 20:17:09.266 | 20:17:09.350 | 84 ms | 0 |
| wait (urunc → runc) | `quay.io/argoproj/argoexec:v4.1.4` | 20:17:16.716 | 20:19:42.785 | 146.1 s | 64 |
| main (urunc → QEMU) | `docker.io/urunc-argo/python-linux-qemu:135` | 20:17:17.120 | 20:17:18.148 | 1.03 s | 0 (QEMU) |

Started = the `urunc start` call in the urunc journal, Completed = containerd's exit event. All times UTC, 2026-09-29.

- `init` and `wait` have no `urunc.json`, so urunc hands them to runc. Only `main` becomes a VM.
- urunc passes `main`'s command to the guest as `init=/var/run/argo/argoexec -- emissary ... -- python /argo/staging/script`. The kernel drops everything after the second `--`, so emissary starts with no command and panics (`slice bounds out of range [1:0]`, emissary.go:99). python never runs.
- Before the panic, emissary writes `ctr/main/exitcode` = 64 into the `var-run-argo` emptyDir over virtiofs, and `wait` reads it on the host ("Main container completed"). So the shared fs works both ways.
- `main` has three exit codes: 64 in the exitcode file, 2 for the argoexec process (`exitcode=0x200`), and 0 for QEMU. Kubernetes only sees QEMU's 0.
- urunc's network setup redirects all of the pod's eth0 ingress to `tap0_urunc` (tc mirred). `wait` shares that network namespace. Its connection to the API server was opened just before the redirect, so the next request hangs until `http2: client connection lost` (20:18:01), and every new connection fails with `no route to host`. The redirect is still there after the VM has exited (`logs/urunc/netns-experiment-gnxvr.while-running.txt`).
- After `main` terminates, the workflow-controller tries to stop `wait` with `argoexec kill` over exec, three times (20:17:31, 20:17:42, 20:18:01). urunc v0.8.0 has no `exec` command, so all three fail. `wait` gives up on its own at 20:19:42 with exit 64 and the workflow goes to `Error`.
- In #135 the exitcode file was never written, so `wait` had nothing to stop on, and the kill exec failed as well. That combination would explain the permanent hang there.
- The urunc handler has no `SystemdCgroup = true`, so `pause`, `init` and `wait` end up under `/system.slice/kubepods-...` instead of the pod slice. It cannot be set on the urunc handler today (every urunc pod fails), see [urunc#1105](https://github.com/urunc-dev/urunc/issues/1105). This did not change the result here.

---

## Scanning the logs

```bash
# the three containers; main.log is the guest's serial console plus virtiofsd debug output
cat logs/kubectl/{init,wait,main}.log

# every urunc call for this pod: create/start/kill/delete, QEMU command line, network setup
cat logs/journalctl/urunc.log

# containerd for this pod (the no-hugetlb file drops the cgroup stats noise)
cat logs/journalctl/containerd.pod-only.no-hugetlb.log

# controller decisions, including the three failed kill execs
cat logs/kubectl/workflow-controller.log

# urunc's own step timestamps (TS00-TS18) for main
cat logs/urunc/timestamps.log

# shared volumes while the pod was alive, and the exitcode main wrote
cat logs/volumes/while-running/tree.txt
cat logs/volumes/while-running/var-run-argo--ctr--main--exitcode
```

---

## Layout

```
manifests/      experiment.yaml, smoke.yaml, runtimeclass.yaml, executor-rbac.yaml, kube-flannel.yml,
                urunc-config.toml, containerd-urunc-handler.toml
image/          bunnyfile for the main image
scripts/        snap.sh (urunc version)
RUNLOG.md       build and run steps
logs/
  setup/        output of each setup step
  kubectl/      per-container logs, controller log, describe, pod/workflow yaml, events, task result, phase watch
  podlogs/      CRI ground truth with stdout/stderr stream markers
  journalctl/   urunc, containerd, kubelet, filtered to this pod
  cri/          crictl ps/pods, per-container inspect, sandbox inspectp, container-pid-map.txt
  process/      ps forest (pod subtree), argoexec, shim, QEMU and virtiofsd argv
  urunc/        state.json of the live containers, timestamps, pod network namespace (tc, ip)
  volumes/      the emptyDir contents, while running and after completion
```

Every log here belongs to one run: workflow `experiment-gnxvr`, pod UID
`d4b00664-1280-4988-8972-b0cf7197d1fc`, 20:16:44 → 20:20:06 UTC on 2026-09-29.
No execsnoop trace was taken in this run, so there is no spawn-sequence file.

Versions: urunc v0.8.0 (27f3d06), QEMU 10.1.1, virtiofsd 1.13.0, guest kernel 6.12.36,
kubeadm/kubelet/kubectl v1.37.0, containerd v2.4.0, runc v1.5.1, CNI plugins v1.9.1,
Flannel v0.28.9, Argo Workflows v4.1.4.
