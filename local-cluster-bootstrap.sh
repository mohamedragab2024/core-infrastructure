#!/bin/bash
# CLean up 
# Remove existing nodes
multipass delete --all
multipass purge
# Configuration variables
MASTER_NODE="k3s-master"
WORKER_NODES=("k3s-worker1" "k3s-worker2")

# Create master node
echo "Creating master node..."
multipass launch --name ${MASTER_NODE} --cpus 2 --memory 2G --disk 10G
multipass exec ${MASTER_NODE} -- bash -c "curl -sfL https://get.k3s.io | sh -s - --disable=servicelb --disable=traefik"

# Get k3s token
MASTER_NODE_TOKEN=$(multipass exec ${MASTER_NODE} sudo cat /var/lib/rancher/k3s/server/node-token)
MASTET_NODE_IP=$(multipass info ${MASTER_NODE} | grep -i ip | awk '{print $2}')
# Apply network config to master
KUBE_CONFIG=$(multipass exec ${MASTER_NODE} -- bash -c "sudo cat /etc/rancher/k3s/k3s.yaml")

# Create worker nodes
for WORKER_NODE in "${WORKER_NODES[@]}"; do
    echo "Creating worker node ${WORKER_NODE}..."
    multipass launch --name ${WORKER_NODE} --cpus 2 --memory 2G --disk 10G
    multipass exec ${WORKER_NODE} -- bash -c "curl -sfL https://get.k3s.io | K3S_URL=https://${MASTET_NODE_IP}:6443 K3S_TOKEN=${MASTER_NODE_TOKEN} sh -"
done
# Wait for all nodes to be ready
echo "Waiting for all nodes to be ready..."
for WORKER_NODE in "${WORKER_NODES[@]}"; do
    multipass exec ${MASTER_NODE} -- bash -c "while ! sudo kubectl get nodes $WORKER_NODE | grep -q 'Ready'; do sleep 5; done"
done

# Install metalLB on master
echo "Installing MetalLB on master node..."
multipass exec ${MASTER_NODE} -- bash -c "sudo kubectl create namespace metallb-system || true"
multipass exec ${MASTER_NODE} -- bash -c "sudo kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml" -n metallb-system
# Configure MetalLB
echo "Configuring MetalLB..."
multipass exec ${MASTER_NODE} -- bash -c "sudo kubectl delete validatingwebhookconfigurations metallb-webhook-configuration"
multipass exec ${MASTER_NODE} -- bash -c "sudo kubectl apply -n metallb-system -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: k3s-pool-ip
  namespace: metallb-system
spec:
 addresses:
  - 192.168.64.110-192.168.64.200
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: k3s-lb-pool
  namespace: metallb-system
spec:
  ipAddressPools:
  - k3s-pool-ip
EOF
"
# Wait for MetalLB to be ready
echo "Waiting for MetalLB to be ready..."
multipass exec ${MASTER_NODE} -- bash -c "while ! sudo kubectl get pods -n metallb-system | grep -q 'Running'; do sleep 5; done"
# Display the cluster information
echo "Cluster information:"
multipass exec ${MASTER_NODE} -- bash -c "sudo kubectl get nodes"
echo "Cluster is ready!"
# Display the kubeconfig file
echo "create Kubeconfig file:"
mkdir -p ~/.kube || true
echo "${KUBE_CONFIG}" >> ~/.kube/k3sconfig
yq e -i '.clusters[0].cluster.server="https://'"${MASTET_NODE_IP}"':6443"' ~/.kube/k3sconfig
echo "Kubeconfig file saved to ~/.kube/k3sconfig"

# Generate SSL certificate for *.apps.local domain
echo "Generating SSL certificates for *.apps.local"
CERT_DIR=~/certs
mkdir -p $CERT_DIR

# Generate a root CA
openssl genrsa -out $CERT_DIR/ca.key 4096
openssl req -x509 -new -nodes -key $CERT_DIR/ca.key -sha256 -days 3650 \
  -out $CERT_DIR/ca.crt -subj "/CN=Local Cluster CA"

# Generate a wildcard certificate for *.apps.local
openssl genrsa -out $CERT_DIR/tls.key 2048
openssl req -new -key $CERT_DIR/tls.key -out $CERT_DIR/tls.csr \
  -subj "/CN=*.apps.local" \
  -addext "subjectAltName = DNS:*.apps.local,DNS:apps.local"

# Sign the certificate with our CA
openssl x509 -req -in $CERT_DIR/tls.csr -CA $CERT_DIR/ca.crt -CAkey $CERT_DIR/ca.key \
  -CAcreateserial -out $CERT_DIR/tls.crt -days 365 -sha256 \
  -extfile <(printf "subjectAltName=DNS:*.apps.local,DNS:apps.local")

# Create cert-manager namespace
echo "Creating cert-manager namespace"
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

# Create CA TLS secret for cert-manager
echo "Creating CA TLS secret for cert-manager"
kubectl create secret tls ca-key-pair \
  --cert=$CERT_DIR/ca.crt \
  --key=$CERT_DIR/ca.key \
  --namespace=cert-manager

# Create wildcard certificate TLS secret
echo "Creating wildcard certificate TLS secret"
kubectl create secret tls wildcard-apps-local-tls \
  --cert=$CERT_DIR/tls.crt \
  --key=$CERT_DIR/tls.key \
  --namespace=cert-manager


# Deploy argocd 
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
echo "Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f "https://raw.githubusercontent.com/mohamedragab2024/core-infrastructure/refs/heads/main/argocd/argocd-values-local.yaml"
echo "Waiting for the service to be ready..."      
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
echo "ArgoCD is ready!"

# deploy core apps
kubectl apply -f "https://raw.githubusercontent.com/mohamedragab2024/core-infrastructure/refs/heads/main/argocd/app-of-apps.yaml"
echo "Core apps are deployed!"
