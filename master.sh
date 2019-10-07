#!/bin/bash -v

curl -fL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet="${k8s_version}*" kubeadm="${k8s_version}*" kubectl="${k8s_version}*" kubernetes-cni docker.io python-pip jq

# Docker sets the policy for the FORWARD chain to DROP, change it back.
iptables -P FORWARD ACCEPT

name=""
while [[ -z "$name" ]]; do
    sleep 1
    name="$(hostname -f)"
done

if [ -z ${k8s_version} ]; then
    k8s_version=$(curl -fL https://storage.googleapis.com/kubernetes-release/release/stable.txt)
else
    k8s_version=v${k8s_version}
fi

# Export userdata template substitution variables.
export pod_cidr="${pod_cidr}"
export service_cidr="${service_cidr}"
export subnet_cidrs="${subnet_cidrs}"
export node_nametag="${node_nametag}"
export aws_access_key_id="${aws_access_key_id}"
export aws_secret_access_key="${aws_secret_access_key}"
export aws_region="${aws_region}"
export default_instance_type="${default_instance_type}"
export default_volume_size="${default_volume_size}"
export boot_image_tags="${boot_image_tags}"
export license_key="${license_key}"
export license_id="${license_id}"
export license_username="${license_username}"
export license_password="${license_password}"
export itzo_url="${itzo_url}"
export itzo_version="${itzo_version}"
export milpa_image="${milpa_image}"

# Set CIDRs for ip-masq-agent.
non_masquerade_cidrs="${pod_cidr}"
for subnet in ${subnet_cidrs}; do
    non_masquerade_cidrs="$non_masquerade_cidrs, $subnet"
done
export non_masquerade_cidrs="$non_masquerade_cidrs"

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
$(if [[ "${network_plugin}" = "kubenet" ]]; then
    echo '    network-plugin: kubenet'
    echo '    non-masquerade-cidr: 0.0.0.0/0'
fi)
---
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
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
$(if [[ "${configure_cloud_routes}" = "true" ]]; then
    echo '    configure-cloud-routes: "true"'
else
    echo '    configure-cloud-routes: "false"'
fi)
    address: 0.0.0.0
kubernetesVersion: "$k8s_version"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
iptables:
  masqueradeAll: true
EOF
kubeadm init --config=/tmp/kubeadm-config.yaml

export KUBECONFIG=/etc/kubernetes/admin.conf

# Configure kubectl.
mkdir -p /home/ubuntu/.kube
sudo cp -i $KUBECONFIG /home/ubuntu/.kube/config
sudo chown ubuntu: /home/ubuntu/.kube/config

# Networking.
if [[ "${network_plugin}" != "kubenet" ]]; then
    curl -fL https://raw.githubusercontent.com/elotl/milpa-deploy/master/deploy/cni/${network_plugin}.yaml | envsubst | kubectl apply -f -
fi

# Create a default storage class, backed by EBS.
curl -fL https://raw.githubusercontent.com/elotl/milpa-deploy/master/deploy/storageclass-ebs.yaml | envsubst | kubectl apply -f -

# Set up ip-masq-agent.
curl -fL https://raw.githubusercontent.com/elotl/milpa-deploy/master/deploy/ip-masq-agent.yaml | envsubst | kubectl apply -f -

# Deploy Kiyot/Milpa components.
curl -fL https://raw.githubusercontent.com/elotl/milpa-deploy/master/deploy/kiyot.yaml | envsubst | kubectl apply -f -

curl -fL https://raw.githubusercontent.com/elotl/milpa-deploy/master/deploy/kiyot-kube-proxy.yaml | envsubst | kubectl apply -f -

curl -fL https://raw.githubusercontent.com/elotl/milpa-deploy/master/deploy/kiyot-device-plugin.yaml | envsubst | kubectl apply -f -

curl -fL https://raw.githubusercontent.com/elotl/milpa-deploy/master/deploy/create-webhook.sh | bash
