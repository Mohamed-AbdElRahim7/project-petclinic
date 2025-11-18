#!/bin/bash
set -xe

# ===== Logging =====
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "════════════════════════════════════════"
echo "User-Data Start: $(date)"
echo "════════════════════════════════════════"

# ===== Basic OS prep =====
echo "[STEP] Update apt & install base tools"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl wget vim git unzip jq \
  apt-transport-https ca-certificates gnupg \
  lsb-release software-properties-common nfs-common \
  socat conntrack ipset

echo "[STEP] Set hostname"
hostnamectl set-hostname ${hostname}
grep -q "${hostname}" /etc/hosts || echo "127.0.0.1 ${hostname}" >> /etc/hosts

echo "[STEP] Disable swap"
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "[STEP] Load kernel modules"
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay || true
modprobe br_netfilter || true

echo "[STEP] Sysctl for Kubernetes networking"
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# ===== Containerd (CRI) =====
echo "[STEP] Install containerd"
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

echo "[STEP] Tune containerd for Kubernetes (systemd cgroups + pause:3.9)"

# systemd cgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# pause image 3.9 بدل 3.8
sed -i 's#sandbox_image = "registry.k8s.io/pause:3.8"#sandbox_image = "registry.k8s.io/pause:3.9"#' /etc/containerd/config.toml

# CRI socket path للتأكيد
grep -q 'disabled_plugins' /etc/containerd/config.toml || true

systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

# ===== crictl config (مفيد في التربيل شوت) =====
echo "[STEP] Configure crictl"
CRICTL_BIN=/usr/local/bin/crictl
if [ ! -x "$CRICTL_BIN" ]; then
  curl -L https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz -o /tmp/crictl.tar.gz
  tar -C /usr/local/bin -xzf /tmp/crictl.tar.gz
  rm -f /tmp/crictl.tar.gz
fi

cat <<EOF >/etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# ===== Kubernetes repo (v1.28) =====
echo "[STEP] Add Kubernetes apt repo (v1.28)"
mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /
EOF

apt-get update -y

echo "[STEP] Install kubeadm / kubelet / kubectl"
DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# kubelet لازم يشتغل بعد containerd
systemctl enable kubelet
systemctl restart kubelet || true

# ===== AWS CLI (اختياري بس بيساعد) =====
echo "[STEP] Install AWS CLI v2"
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install || true
rm -rf aws awscliv2.zip

# ===== CloudWatch Agent (لو حابب تراقب اللوجات بعدين) =====
echo "[STEP] Install CloudWatch Agent (optional)"
cd /tmp
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazoncloudwatch-agent.deb
dpkg -i -E amazoncloudwatch-agent.deb || true
rm -f amazoncloudwatch-agent.deb

echo "════════════════════════════════════════"
echo "User-Data Complete: $(date)"
echo "════════════════════════════════════════"

echo "[STEP] Create node-ready marker"
touch /tmp/node-ready
chmod 644 /tmp/node-ready

echo "✅ Node ready for Ansible (kubeadm init / join)"
