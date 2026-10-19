#!/usr/bin/env bash
# snap.sh <label> [namespace] - freeze Argo/K8s/runtime/process/urunc state.
# Adapted from argo-runc/scripts/snap.sh for urunc (Linux guest over virtiofs).
set -uo pipefail

LABEL="${1:-snap}"
NS="${2:-argo}"
W=/root/urunc-argo-135
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$W/captures/${TS}-${LABEL}"
# journal window starts at the workflow submit time (written by the submit step)
SINCE="$(cat "$W/captures/SUBMIT_TIME" 2>/dev/null || echo '30 min ago')"
mkdir -p "$OUT"/{k8s,runtime,process,podlogs,journal,volumes,urunc}

log(){ printf '  %-28s %s\n' "$1" "$2"; }
run(){ local f="$1"; shift; "$@" >"$f" 2>&1; }

echo "[snap] -> $OUT (journal since: $SINCE)"

### Plane 1: Kubernetes / orchestration
run "$OUT/k8s/workflows.yaml"      kubectl get wf -n "$NS" -o yaml
run "$OUT/k8s/workflows.txt"       kubectl get wf -n "$NS" -o wide
run "$OUT/k8s/taskresults.yaml"    kubectl get workflowtaskresults -n "$NS" -o yaml
run "$OUT/k8s/pods.yaml"           kubectl get pods -n "$NS" -o yaml
run "$OUT/k8s/pods-wide.txt"       kubectl get pods -n "$NS" -o wide
run "$OUT/k8s/events.txt"          kubectl get events -n "$NS" --sort-by=.lastTimestamp
run "$OUT/k8s/nodes.txt"           kubectl get nodes -o wide
run "$OUT/k8s/controller.log"      kubectl logs -n argo deploy/workflow-controller --tail=300
log "kubernetes" "workflows, taskresults, pods, events, controller"

# Per-pod: describe + logs from EVERY container (kubectl logs defaults to main only)
for pod in $(kubectl get pods -n "$NS" -o name 2>/dev/null | cut -d/ -f2); do
  kubectl describe pod -n "$NS" "$pod" > "$OUT/k8s/describe-${pod}.txt" 2>&1
  for c in $(kubectl get pod -n "$NS" "$pod" \
               -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null); do
    kubectl logs -n "$NS" "$pod" -c "$c" --timestamps > "$OUT/k8s/logs-${pod}-${c}.log" 2>&1
    kubectl logs -n "$NS" "$pod" -c "$c" --previous > "$OUT/k8s/logs-${pod}-${c}.prev.log" 2>&1
    pf="$OUT/k8s/logs-${pod}-${c}.prev.log"
    if [ ! -s "$pf" ] || grep -q 'previous terminated container' "$pf" 2>/dev/null; then rm -f "$pf"; fi
  done
done
log "pod logs" "all containers incl. init + wait (main = guest console)"

### Plane 2: container runtime (CRI)
run "$OUT/runtime/crictl-ps.txt"     crictl ps -a
run "$OUT/runtime/crictl-pods.txt"   crictl pods
run "$OUT/runtime/crictl-images.txt" crictl images
run "$OUT/runtime/crictl-info.json"  crictl info
for cid in $(crictl ps -a -q 2>/dev/null); do
  crictl inspect "$cid" > "$OUT/runtime/inspect-${cid:0:12}.json" 2>&1
done
for sid in $(crictl pods -q 2>/dev/null); do
  crictl inspectp "$sid" > "$OUT/runtime/inspectp-${sid:0:12}.json" 2>&1
done
{
  printf '%-14s %-34s %-10s %-8s %s\n' CONTAINER NAME STATE PID CGROUP
  for cid in $(crictl ps -a -q 2>/dev/null); do
    j=$(crictl inspect "$cid" 2>/dev/null)
    nm=$(jq -r '.status.metadata.name // "?"'  <<<"$j")
    st=$(jq -r '.status.state // "?"'          <<<"$j")
    pid=$(jq -r '.info.pid // "?"'             <<<"$j")
    cg=$(jq -r '.info.runtimeSpec.linux.cgroupsPath // "?"' <<<"$j")
    printf '%-14s %-34s %-10s %-8s %s\n' "${cid:0:12}" "$nm" "$st" "$pid" "$cg"
  done
} > "$OUT/runtime/container-pid-map.txt" 2>&1
log "runtime" "crictl ps/inspect/inspectp + container->PID map"

### Plane 3: Linux processes & cgroups
run "$OUT/process/ps-forest.txt"  ps -ef --forest
run "$OUT/process/ps-full.txt"    ps -eo pid,ppid,pgid,stat,lstart,comm,args
{ command -v systemd-cgls >/dev/null && systemd-cgls --no-pager; } > "$OUT/process/cgls.txt" 2>&1
find /sys/fs/cgroup/kubepods.slice -maxdepth 5 -name cgroup.procs 2>/dev/null \
  | while read -r f; do
      pids=$(tr '\n' ' ' < "$f" 2>/dev/null)
      [ -n "${pids// /}" ] && printf '%s\n    %s\n' "${f%/cgroup.procs}" "$pids"
    done > "$OUT/process/cgroup-tree.txt" 2>&1
# host-side argv of argoexec (init/wait on runc), qemu, virtiofsd, urunc shims.
# main's argoexec runs INSIDE the guest and is not visible here.
for pat in argoexec qemu-system virtiofsd containerd-shim-urunc containerd-shim-runc; do
  { for p in $(pgrep -f "[${pat:0:1}]${pat:1}" 2>/dev/null); do
      [ "$p" = "$$" ] && continue
      a0=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -1)
      case "$(basename "${a0:-none}")" in bash|sh|pgrep) continue;; esac
      echo "=== PID $p  PPID $(awk '{print $4}' /proc/$p/stat 2>/dev/null) ==="
      tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null; echo
      echo "  cgroup: $(sed -n 's/^0:://p' /proc/$p/cgroup 2>/dev/null)"
    done; } > "$OUT/process/${pat}-procs.txt" 2>&1
done
log "process" "ps forest, cgroups, argoexec/qemu/virtiofsd/shim argv"

### urunc: state dirs, timestamps, pod netns tc (urunc redirects eth0 ingress to tap0_urunc)
for d in /run/containerd/runc/k8s.io/*/; do
  cid=$(basename "$d")
  [ -f "$d/state.json" ] || continue
  mkdir -p "$OUT/urunc/state/${cid:0:12}"
  cp -r "$d"/* "$OUT/urunc/state/${cid:0:12}/" 2>/dev/null
done
cp /var/log/urunc/timestamps.log "$OUT/urunc/timestamps.log" 2>/dev/null
for sid in $(crictl pods -q --namespace "$NS" 2>/dev/null); do
  pod=$(crictl inspectp "$sid" 2>/dev/null | jq -r '.status.metadata.name')
  pid=$(crictl inspectp "$sid" 2>/dev/null | jq -r '.info.pid // empty')
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || continue
  { echo "# pod $pod sandbox ${sid:0:12} pause pid $pid"
    nsenter -t "$pid" -n ip -d addr
    echo "## tc qdisc"; nsenter -t "$pid" -n tc qdisc show
    for dev in eth0 tap0_urunc; do
      echo "## tc filter $dev ingress"; nsenter -t "$pid" -n tc filter show dev "$dev" ingress
    done
    echo "## routes"; nsenter -t "$pid" -n ip route
  } > "$OUT/urunc/netns-${pod}.txt" 2>&1
done
log "urunc" "state dirs, timestamps, pod netns tc/ip"

### Journald (since submit) + /var/log/pods
journalctl -u kubelet    --since "$SINCE" --no-pager -o short-iso-precise > "$OUT/journal/kubelet.log"    2>&1
journalctl -u containerd --since "$SINCE" --no-pager -o short-iso-precise > "$OUT/journal/containerd.log" 2>&1
journalctl -t urunc      --since "$SINCE" --no-pager -o short-iso-precise > "$OUT/journal/urunc.log"      2>&1
journalctl -k            --since "$SINCE" --no-pager -o short-iso-precise > "$OUT/journal/kernel.log"     2>&1
for d in /var/log/pods/${NS}_*; do
  [ -d "$d" ] && cp -r "$d" "$OUT/podlogs/" 2>/dev/null
done
log "journald + /var/log/pods" "kubelet, containerd, urunc, kernel"

### Pod emptyDir volumes - ctr/main/exitcode present or not is the hang evidence
for pod in $(kubectl get pods -n "$NS" -o name 2>/dev/null | cut -d/ -f2); do
  u=$(kubectl get pod -n "$NS" "$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  [ -n "$u" ] || continue
  vd="/var/lib/kubelet/pods/$u/volumes/kubernetes.io~empty-dir"
  [ -d "$vd" ] || continue
  find "$vd" -mindepth 1 -printf '%TY-%Tm-%Td %TH:%TM:%.2TS  %y %12s  %p\n' \
    > "$OUT/volumes/tree-${pod}.txt" 2>&1
  [ -s "$OUT/volumes/tree-${pod}.txt" ] || \
    echo "(no emptyDir volumes present - pod had terminated and kubelet reclaimed them)" \
      > "$OUT/volumes/tree-${pod}.txt"
  find "$vd" -type f -size -1048576c -print0 2>/dev/null | while IFS= read -r -d '' f; do
    rel="${f#$vd/}"; mkdir -p "$OUT/volumes/${pod}/$(dirname "$rel")"
    cp "$f" "$OUT/volumes/${pod}/$rel" 2>/dev/null
  done
  ec=$(find "$vd" -path '*ctr/main/exitcode' 2>/dev/null | head -1)
  if [ -n "$ec" ]; then echo "$pod: ctr/main/exitcode = $(cat "$ec")"; else echo "$pod: ctr/main/exitcode MISSING"; fi \
    >> "$OUT/volumes/exitcode-summary.txt"
done
log "pod volumes" "emptyDir trees, files <1M, exitcode summary"

du -sh "$OUT" | awk '{print "[snap] done: "$1"  "$2}'
