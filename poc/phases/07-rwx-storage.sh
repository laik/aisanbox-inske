#!/usr/bin/env bash
# Phase 2b —— 支持 ReadWriteMany 的存储 (POC2 §5.2)
# 手工重现: bash poc/phases/07-rwx-storage.sh
#
# POC2 §5.2 说得很清楚: Kind 默认的 local-path StorageClass 不提供真正的 RWX，
# 而且「不要把 PVC 声明为 RWX 就当作底层存储已经支持 RWX」。
# 这一阶段就是按它说的做: 装 NFS Server + Subdir External Provisioner，
# 然后用**两个 Pod 同时读写同一个卷**来证明 RWX 是真的。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
NS=tenant-a-runtime

helm repo add nfs-ganesha-stable https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ >/dev/null 2>&1 || true
helm repo update nfs-ganesha-stable >/dev/null 2>&1 || true
kubectl --context $CTX create ns nfs-provisioner --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm --kube-context $CTX upgrade --install nfs nfs-ganesha-stable/nfs-server-provisioner \
  --version 1.8.0 -n nfs-provisioner \
  --set storageClass.name=rwx-shared \
  --set storageClass.reclaimPolicy=Delete \
  --set persistence.size=10Gi \
  --wait --timeout 6m

echo "### StorageClass"
kubectl --context $CTX get storageclass | sed 's/^/   /'
echo
echo "### 反证: 同样的 RWX 声明放在默认 local-path 上会怎样"
kubectl --context $CTX -n $NS delete pvc probe-localpath-rwx --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX -n $NS apply -f storage/localpath-rwx-probe.yaml >/dev/null
sleep 5
kubectl --context $CTX -n $NS get pvc probe-localpath-rwx --no-headers | awk '{print "   local-path RWX PVC: phase="$2" volume="$3}'
echo "   → API **接受**了这个声明(不校验底层能力)，但 local-path 的 PV 是 hostPath，"
echo "     本质是 RWO。PVC 停在 Pending/单节点，跨节点第二个 Pod 挂不上。"
echo "     这就是 POC2 §5.2 那句「不要把 PVC 声明为 RWX 就当作底层已经支持 RWX」的意思。"

echo
echo "### 正证: rwx-shared 上，两个 Pod(强制跨节点)读写同一份数据"
kubectl --context $CTX -n $NS delete pod rwx-a rwx-b --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX -n $NS delete pvc rwx-probe --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX -n $NS apply -f storage/rwx-probe.yaml >/dev/null
kubectl --context $CTX -n $NS wait --for=condition=Ready pod/rwx-a pod/rwx-b --timeout=240s 2>&1 | sed 's/^/   /'
kubectl --context $CTX -n $NS get pod rwx-a rwx-b --no-headers \
  -o 'jsonpath={range .items[*]}{.metadata.name}{" node="}{.spec.nodeName}{"\n"}{end}' | sed 's/^/   /'
kubectl --context $CTX -n $NS get pvc rwx-probe --no-headers | awk '{print "   pvc phase="$2" vol="$3}'
echo "   a 写 -> b 读:"
kubectl --context $CTX -n $NS exec rwx-a -- sh -c 'echo hello-from-a > /data/from-a.txt'
kubectl --context $CTX -n $NS exec rwx-b -- sh -c 'cat /data/from-a.txt' 2>&1 | sed 's/^/      b 读到: /'
echo "   b 写 -> a 读(两个都在挂载中):"
kubectl --context $CTX -n $NS exec rwx-b -- sh -c 'echo hello-from-b > /data/from-b.txt'
kubectl --context $CTX -n $NS exec rwx-a -- sh -c 'cat /data/from-b.txt' 2>&1 | sed 's/^/      a 读到: /'
echo "   同一文件并发追加(证明是同一份，不是各自副本):"
kubectl --context $CTX -n $NS exec rwx-a -- sh -c 'for i in $(seq 1 50); do printf "a%s\n" "$i" >> /data/both.txt; done'
kubectl --context $CTX -n $NS exec rwx-b -- sh -c 'for i in $(seq 1 50); do printf "b%s\n" "$i" >> /data/both.txt; done'
kubectl --context $CTX -n $NS exec rwx-a -- sh -c 'printf "总行数=%s a=%s b=%s\n" "$(wc -l < /data/both.txt)" "$(grep -c "^a" /data/both.txt)" "$(grep -c "^b" /data/both.txt)"' | sed 's/^/      /'
echo
echo "### 顺带: 删除其中一个 Pod，不影响另一个正在挂载的卷(POC2 §10.5 的前置)"
kubectl --context $CTX -n $NS delete pod rwx-b --wait=true
kubectl --context $CTX -n $NS exec rwx-a -- sh -c 'cat /data/from-b.txt' 2>&1 | sed 's/^/      rwx-a 仍读到 b 写的文件: /'

kubectl --context $CTX -n $NS delete pod rwx-a --ignore-not-found >/dev/null 2>&1
kubectl --context $CTX -n $NS delete pvc rwx-probe probe-localpath-rwx --ignore-not-found >/dev/null 2>&1
echo
echo "### 交付物(给 Phase 3): StorageClass rwx-shared"
echo "    真正的 workspace PVC 在 Phase 3 由 OpenShell 的 resource admission 流程创建。"
kubectl --context $CTX get storageclass rwx-shared -o 'jsonpath={"   name="}{.metadata.name}{"  provisioner="}{.provisioner}{"  reclaim="}{.reclaimPolicy}{"\n"}'
