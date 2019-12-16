#!/bin/bash -v

curl -fL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-add-repository ppa:projectatomic/ppa
apt-get update -qq
if [[ "${container_runtime}" = "crio" ]]; then
    apt-get install -y kubelet="${k8s_version}*" kubeadm="${k8s_version}*" kubectl="${k8s_version}*" kubernetes-cni cri-o-1.15 python-pip jq
else
    apt-get install -y kubelet="${k8s_version}*" kubeadm="${k8s_version}*" kubectl="${k8s_version}*" kubernetes-cni containerd
fi

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

if [[ "${container_runtime}" = "crio" ]]; then
    # Cri-o configuration.
    pip install remarshal
    remarshal --if toml -i /etc/crio/crio.conf --of json | jq ".crio.runtime.cgroup_manager=\"cgroupfs\" | .crio.runtime.conmon = \"$(which conmon)\" | .crio.image.registries=[\"docker.io\"]" | remarshal --if json --of toml > /tmp/crio.conf; mv /tmp/crio.conf /etc/crio/crio.conf
    rm -f /etc/cni/net.d/*
    mkdir -p /usr/local/libexec
    ln -s /usr/libexec/crio /usr/local/libexec/crio
fi

# Enable primary container runtime.
systemctl enable ${container_runtime}
systemctl restart ${container_runtime}

# Install criproxy.
curl -fL https://github.com/elotl/criproxy/releases/download/v0.15.1/criproxy > /usr/local/bin/criproxy; chmod 755 /usr/local/bin/criproxy
cat <<EOF > /etc/systemd/system/criproxy.service
[Unit]
Description=CRI Proxy
Wants=${container_runtime}.service

[Service]
ExecStart=/usr/local/bin/criproxy -v 3 -logtostderr -connect /run/${container_runtime}/${container_runtime}.sock,kiyot:/run/milpa/kiyot.sock -listen /run/criproxy.sock
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
