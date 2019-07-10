#!/bin/bash -v

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet=${k8s_version} kubeadm=${k8s_version} kubectl=${k8s_version} kubernetes-cni containerd python-pip jq

modprobe br_netfilter
sysctl net.bridge.bridge-nf-call-iptables=1
sysctl net.ipv4.ip_forward=1

mkdir -p /etc/cni/net.d
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
      "ipMasq": true,
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
systemctl restart containerd

name=""
while [[ -z "$name" ]]; do
    sleep 1
    name="$(hostname -f)"
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
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    cloud-provider: aws
    network-plugin: kubenet
    non-masquerade-cidr: 0.0.0.0/0
    node-labels: kubernetes.io/role=worker
EOF

for i in {1..50}; do kubeadm join --config=/tmp/kubeadm-config.yaml && break || sleep 15; done
