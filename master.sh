#!/bin/bash -v

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl kubernetes-cni
curl -sSL https://get.docker.com/ | sh
systemctl start docker

modprobe br_netfilter
sysctl net.bridge.bridge-nf-call-iptables=1
sysctl net.ipv4.ip_forward=1
iptables -P FORWARD ACCEPT

name=""
while [[ -z "$name" ]]; do
    sleep 1
    name="$(hostname -f)"
done

# When using kubenet, we rely on the cloud controller to create cloud routes
# for the pod subnet CIDR that gets allocated to each worker node. When using
# CNI, however, we expect the plugin to configure routing.
configure_cloud_routes="true"
if [[ "${network_plugin}" != "kubenet" ]]; then
    configure_cloud_routes="false"
fi

cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta1
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: ${k8stoken}
nodeRegistration:
  name: $name
  kubeletExtraArgs:
    cloud-provider: aws
    network-plugin: ${network_plugin}
    non-masquerade-cidr: 0.0.0.0/0
---
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
dns:
  type: kube-dns
networking:
  podSubnet: ${pod_cidr}
  serviceSubnet: ${service_cidr}
apiServer:
  extraArgs:
    enable-admission-plugins: DefaultStorageClass,NodeRestriction
    cloud-provider: aws
controllerManager:
  extraArgs:
    cloud-provider: aws
    configure-cloud-routes: "$configure_cloud_routes"
    address: 0.0.0.0
EOF
kubeadm init --config=/tmp/kubeadm-config.yaml

export KUBECONFIG=/etc/kubernetes/admin.conf

# Configure kubectl.
mkdir -p /home/ubuntu/.kube
sudo cp -i $KUBECONFIG /home/ubuntu/.kube/config
sudo chown ubuntu: /home/ubuntu/.kube/config

kubectl get cm -n kube-system kube-proxy -oyaml | sed -r '/^\s+resourceVersion:/d' | sed 's/masqueradeAll: false/masqueradeAll: true/' | kubectl replace -f -

kubectl patch -n kube-system deployment kube-dns --patch '{"spec": {"template": {"spec": {"tolerations": [{"key": "CriticalAddonsOnly", "operator": "Exists"}]}}}}'

cat <<EOF > /tmp/storageclass.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: ebs
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/aws-ebs
volumeBindingMode: Immediate
reclaimPolicy: Retain
EOF
kubectl apply -f /tmp/storageclass.yaml

if [[ "${network_plugin}" = "kubenet" ]]; then
    mkdir -p /tmp/ip-masq-agent-config
    cat <<EOF > /tmp/ip-masq-agent-config/config
nonMasqueradeCIDRs:
  - ${pod_cidr}
  - ${subnet_cidr}
EOF
    kubectl create -n kube-system configmap ip-masq-agent --from-file=/tmp/ip-masq-agent-config/config
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-incubator/ip-masq-agent/master/ip-masq-agent.yaml
elif [[ "${network_plugin}" = "cni" ]]; then
    kubectl apply -f https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml
else
    echo "WARNING: network plugin ${network_plugin} not recognized"
fi
