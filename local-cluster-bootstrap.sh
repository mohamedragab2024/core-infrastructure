#!/bin/bash
# Check multipass installation
if ! command -v multipass &> /dev/null
then
    echo "Multipass could not be found. Please install it first. https://canonical.com/multipass/install"
    exit
fi
network=$1
# Remove existing nodes
multipass delete --all
multipass purge

# Define node names
MASTER_NODE="k3s-master"
WORKER_NODES_COUNT=${2:-0}

# Create master node
echo "Creating master node..."
if [[ -z "$network" ]]; then
    multipass launch --name ${MASTER_NODE} --cpus 2 --memory 2G --disk 10G
else
    multipass launch --name ${MASTER_NODE} --cpus 2 --memory 2G --disk 10G --network $network
fi
multipass exec ${MASTER_NODE} -- bash -c "curl -sfL https://get.k3s.io | sh -s - --disable=servicelb --disable=traefik"

# Get k3s token
MASTER_NODE_TOKEN=$(multipass exec ${MASTER_NODE} sudo cat /var/lib/rancher/k3s/server/node-token)
MASTET_NODE_IP=$(multipass info ${MASTER_NODE} | grep -i ip | awk '{print $2}')
# Get kubeconfig
KUBE_CONFIG=$(multipass exec ${MASTER_NODE} -- bash -c "sudo cat /etc/rancher/k3s/k3s.yaml")

# Create worker nodes
if [[ ${WORKER_NODES_COUNT} -eq 0 ]]; then
  echo "No worker nodes to create. Proceeding with master node only..."
else
  for i in $(seq 1 ${WORKER_NODES_COUNT}); do
    WORKER_NODE="k3s-worker-${i}"
    echo "Creating worker node ${WORKER_NODE}..."
    if [[ -n "$network" ]]; then
      multipass launch --name ${WORKER_NODE} --cpus 2 --memory 2G --disk 10G --network $network
    else
      multipass launch --name ${WORKER_NODE} --cpus 2 --memory 2G --disk 10G
    fi
    multipass exec ${WORKER_NODE} -- bash -c "curl -sfL https://get.k3s.io | K3S_URL=https://${MASTET_NODE_IP}:6443 K3S_TOKEN=${MASTER_NODE_TOKEN} sh -"
  done
  # Wait for all nodes to be ready
  echo "Waiting for all nodes to be ready..."
  for i in $(seq 1 ${WORKER_NODES_COUNT}); do
    WORKER_NODE="k3s-worker-${i}"
    multipass exec ${MASTER_NODE} -- bash -c "while ! sudo kubectl get nodes $WORKER_NODE | grep -q 'Ready'; do sleep 5; done"
  done
fi

# Install metalLB on master
echo "Installing MetalLB on master node..."
multipass exec ${MASTER_NODE} -- bash -c "sudo kubectl create namespace metallb-system || true"
multipass exec ${MASTER_NODE} -- bash -c "sudo kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml" -n metallb-system
# Get the network Ip range 
# if network is not provided, get the network IP range from the network interface
# if network is provided, use the the multipass network interface
dhcp=""
if [[ -z "$network" ]]; then
    dhcp=$(multipass info ${MASTER_NODE} | grep -i ip | awk '{print $2}' | cut -d '.' -f 1-3)
else
    dhcp=$(ifconfig $network | grep "inet " | awk '{print $2}' | cut -d '.' -f 1-3)
fi
ipRange=${dhcp}.110-${dhcp}.200

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
  - $ipRange
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
export KUBECONFIG=$KUBECONFIG:~/.kube/k3sconfig
kubectl config use-context default
# Generate SSL certificate for *.apps.local domain
echo "Generating SSL certificates for *.apps.local"
CERT_DIR=~/certs
mkdir -p $CERT_DIR

# Generate a root CA
openssl genrsa -out $CERT_DIR/ca.key 4096
# Create an openssl configuration file for the CA
cat > $CERT_DIR/ca.cnf << EOL
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = Local Cluster CA

[v3_req]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
EOL

# Generate CA certificate with CA:TRUE flag
openssl req -x509 -new -nodes -key $CERT_DIR/ca.key -sha256 -days 3650 \
  -out $CERT_DIR/ca.crt -config $CERT_DIR/ca.cnf -extensions v3_req

# Generate a wildcard certificate for *.apps.local
openssl genrsa -out $CERT_DIR/tls.key 2048

# Create an openssl configuration file for the wildcard cert
cat > $CERT_DIR/cert.cnf << EOL
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.apps.local

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.apps.local
DNS.2 = apps.local
EOL

# Generate CSR with the configuration
openssl req -new -key $CERT_DIR/tls.key -out $CERT_DIR/tls.csr -config $CERT_DIR/cert.cnf

# Create an openssl extension file for signing
cat > $CERT_DIR/cert.ext << EOL
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.apps.local
DNS.2 = apps.local
EOL

# Sign the certificate with our CA using the extension file
openssl x509 -req -in $CERT_DIR/tls.csr -CA $CERT_DIR/ca.crt -CAkey $CERT_DIR/ca.key \
  -CAcreateserial -out $CERT_DIR/tls.crt -days 365 -sha256 -extfile $CERT_DIR/cert.ext

# Create cert-manager namespace
echo "Creating cert-manager namespace"
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

# Create CA TLS secret for cert-manager
echo "Creating CA TLS secret for cert-manager"
kubectl create secret tls ca-key-pair \
  --cert=$CERT_DIR/ca.crt \
  --key=$CERT_DIR/ca.key \
  --namespace=cert-manager --dry-run=client -o yaml | kubectl apply -f -

# Verify the CA certificate has CA flag set
echo "Verifying CA certificate has proper CA flag..."
openssl x509 -in $CERT_DIR/ca.crt -text -noout | grep -A1 "X509v3 Basic Constraints"

# trust the CA certificate on macos
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "Trusting CA certificate on macOS..."
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CERT_DIR/ca.crt
fi
# trust the CA certificate on linux
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  echo "Trusting CA certificate on Linux..."
  sudo cp $CERT_DIR/ca.crt /usr/local/share/ca-certificates/ca.crt
  sudo update-ca-certificates
fi
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

echo "Wait for app of apps to be synced"

# Argocd application is CRDS which is not support waiting for it to be ready
echo "Waiting for app-of-apps to be synced and healthy (this may take a few minutes)..."
timeout=600
start_time=$(date +%s)
while true; do
  # Get the sync and health status
  sync_status=$(kubectl get application app-of-apps -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health_status=$(kubectl get application app-of-apps -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
  
  # Check if we have the desired status
  if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
    echo "✅ app-of-apps is now Synced and Healthy!"
    break
  fi
  
  # Check if timeout has been reached
  current_time=$(date +%s)
  elapsed_time=$((current_time - start_time))
  if [[ $elapsed_time -ge $timeout ]]; then
    echo "⚠️ Timeout waiting for app-of-apps to be Synced and Healthy. Current status: Sync=$sync_status, Health=$health_status"
    echo "Continuing with the bootstrap process anyway..."
    break
  fi
  
  echo "Current status: Sync=$sync_status, Health=$health_status. Waiting..."
  sleep 10
done

# Wait until nginx-ingress is created
echo "wait for nginx to be deployed"
while ! kubectl get deployment nginx-ingress-controller -n ingress-nginx &>/dev/null; do
  echo "Waiting for nginx-ingress-controller deployment to be created..."
  sleep 5
done
kubectl wait --for=condition=available --timeout=600s deployment/nginx-ingress-controller -n ingress-nginx



echo "All ArgoCD applications are synced and healthy!"

# Display the ArgoCD URL
echo "ArgoCD URL: https://argocd.apps.local"
echo "ArgoCD admin password: $(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode)"

# Add argocd domain to /etc/hosts
echo "Please add argocd domain to /etc/hosts... with IP $(kubectl get service ingress-nginx-controller -n ingress-nginx -o yaml | yq '.status.loadBalancer.ingress[].ip')"

echo "If you are using macos and certificate is not trusted, you can use the following command to trust it"
echo  "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/certs/ca.crt"
