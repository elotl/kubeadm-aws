#!/bin/bash -v

backup_binary() {
    local bin=$1
    local path=$(which $bin)
    if [[ -n "$path" ]]; then
        mv $path $path.orig
    fi
}

install_via_apt() {
    curl -fL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
    apt-get update
    apt-get install -y kubelet="${k8s_version}*" kubeadm="${k8s_version}*" kubectl="${k8s_version}*" kubernetes-cni containerd
}

install_via_curl() {
    local CNI_VERSION="v0.8.2"
    rm -rf /opt/cni/bin
    mkdir -p /opt/cni/bin
    curl -L "https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/cni-plugins-linux-amd64-$CNI_VERSION.tgz" | tar -C /opt/cni/bin -xz

    mkdir -p /usr/local/bin

    # Install crictl (required for kubeadm).
    local CRICTL_VERSION="v1.16.0"
    backup_binary crictl
    curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-amd64.tar.gz" | tar -C /usr/local/bin -xz

    # Install kubeadm, kubelet, kubectl and add a kubelet systemd service.
    local RELEASE="${k8s_version}"
    if [[ -z $RELEASE ]]; then
        RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
    fi

    cd /usr/local/bin
    for bin in kubeadm kubelet kubectl; do
        backup_binary $bin
    done
    curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/$RELEASE/bin/linux/amd64/{kubeadm,kubelet,kubectl}
    chmod +x {kubeadm,kubelet,kubectl}

    rm -rf /etc/systemd/system/kubelet.service
    curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/$RELEASE/build/debs/kubelet.service" | sed "s:/usr/bin:/usr/local/bin:g" > /etc/systemd/system/kubelet.service
    rm -rf /etc/systemd/system/kubelet.service.d
    mkdir -p /etc/systemd/system/kubelet.service.d
    curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/$RELEASE/build/debs/10-kubeadm.conf" | sed "s:/usr/bin:/usr/local/bin:g" > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    systemctl enable --now kubelet
}

which apt-get && install_via_apt || install_via_curl
which yum && yum install -y bind-utils

modprobe br_netfilter
sysctl net.bridge.bridge-nf-call-iptables=1; echo "net.bridge.bridge-nf-call-iptables=1" >> /etc/sysctl.conf
sysctl net.ipv4.ip_forward=1; echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
mkdir -p /etc/cni/net.d

if [[ "${network_plugin}" = "kubenet" ]]; then
    # For kubenet, containerd needs a cni config template so it will use the
    # node's pod CIDR.
    mkdir -p /etc/containerd
    cat <<EOF > /etc/containerd/config.toml
[plugins.cri]
  [plugins.cri.cni]
    conf_template = "/etc/containerd/cni-template.json"
EOF
    cat <<EOF > /etc/containerd/cni-template.json
{
  "cniVersion": "0.3.1",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": false,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "subnet": "{{.PodCIDR}}",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF
fi
systemctl enable containerd
systemctl restart containerd

# Install criproxy.
curl -fL https://github.com/elotl/criproxy/releases/download/v0.15.1/criproxy > /usr/local/bin/criproxy; chmod 755 /usr/local/bin/criproxy
cat <<EOF > /etc/systemd/system/criproxy.service
[Unit]
Description=CRI Proxy
Wants=containerd.service

[Service]
ExecStart=/usr/local/bin/criproxy -v 3 -logtostderr -connect /run/containerd/containerd.sock,kiyot:/run/milpa/kiyot.sock -listen /run/criproxy.sock
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=kubelet.service
EOF
systemctl daemon-reload
systemctl enable criproxy
systemctl restart criproxy

# Configure kubelet.
name=""
while [[ -z "$name" ]]; do
    sleep 1
    name="$(hostname -f)"
done

ip=""
while [[ -z "$ip" ]]; do
    sleep 1
    ip="$(host $name | awk '{print $4}')"
done

cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta1
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: ${k8stoken}
    unsafeSkipCAVerification: true
    apiServerEndpoint: ${masterIP}:6443
nodeRegistration:
  name: $name
  criSocket: unix:///run/criproxy.sock
  kubeletExtraArgs:
    node-ip: $ip
    cloud-provider: aws
$(if [[ "${network_plugin}" = "kubenet" ]]; then
    echo "    network-plugin: kubenet"
    echo "    non-masquerade-cidr: 0.0.0.0/0"
fi)
    max-pods: "1000"
    node-labels: elotl.co/milpa-worker=""
EOF

# Override number of CPUs and memory cadvisor reports.
infodir=/opt/kiyot/proc
mkdir -p $infodir; rm -f $infodir/{cpu,mem}info
for i in $(seq 0 1023); do
    cat << EOF >> $infodir/cpuinfo
processor	: $i
physical id	: 0
core id		: 0
cpu MHz		: 2400.068
EOF
done

mem=$((4096*1024*1024))
cat << EOF > $infodir/meminfo
$(printf "MemTotal:%15d kB" $mem)
SwapTotal:             0 kB
EOF

cat <<EOF > /etc/systemd/system/kiyot-override-proc.service
[Unit]
Description=Override /proc info files
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=/bin/mount --bind $infodir/cpuinfo /proc/cpuinfo
ExecStart=/bin/mount --bind $infodir/meminfo /proc/meminfo
RemainAfterExit=true
ExecStop=/bin/umount /proc/cpuinfo
ExecStop=/bin/umount /proc/meminfo
StandardOutput=journal
EOF
systemctl daemon-reload
systemctl enable kiyot-override-proc
systemctl restart kiyot-override-proc

# Join cluster.
kubeadm join --config=/tmp/kubeadm-config.yaml
