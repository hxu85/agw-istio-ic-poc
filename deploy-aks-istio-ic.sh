export CLUSTER=aks-agw-istio-ic-poc
export RESOURCE_GROUP=rg-agw-istio-ic-poc
export LOCATION=eastus
export AKS_VNET_NAME=vnet-aks-agw-istio-ic-poc
export AKS_SUBNET_NAME=snet-aks-agw-istio-ic-poc

az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

#create AKS Vnet with non-default IP Address space - https://learn.microsoft.com/en-us/azure/aks/configure-kubenet
az network vnet create \
    --resource-group ${RESOURCE_GROUP} \
    --name ${AKS_VNET_NAME} \
    --address-prefixes 10.240.0.0/12 \
    --subnet-name ${AKS_SUBNET_NAME} \
    --subnet-prefix 10.240.0.0/16

AKS_SUBNET_ID=$(az network vnet subnet show --resource-group ${RESOURCE_GROUP} --vnet-name ${AKS_VNET_NAME} --name ${AKS_SUBNET_NAME} --query id -o tsv)

az aks create \
--resource-group ${RESOURCE_GROUP} \
--name ${CLUSTER} \
--network-plugin kubenet \
--vnet-subnet-id $AKS_SUBNET_ID \
#--generate-ssh-keys

#switch to AKS context 
az aks get-credentials --resource-group rg-agw-istio-ic-poc --name aks-agw-istio-ic-poc

##install istio using helm https://istio.io/latest/docs/setup/install/helm/

#configure Healm repository
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

#create namespace istio-system
kubectl create namespace istio-system

#install istio base chart
helm install istio-base istio/base -n istio-system

#validate CRD installation 
helm ls -n istio-system

#Install the Istio discovery chart which deploys the istiod service
helm install istiod istio/istiod -n istio-system --wait

#Verify the Istio discovery chart installation
helm ls -n istio-system

#get status of the istiod chart 
helm status istiod -n istio-system

#Check istiod service is successfully installed and its pods are running
kubectl get deployments -n istio-system --output wide

## Install Istio Gateway using K8s YAML, https://istio.io/latest/docs/setup/additional-setup/gateway/
kubectl create namespace istio-ingress

kubectl apply -f install-istio-gateway-ext-lb.yaml # this create external LB and associated public IP in the AKS infra RG

#enable sidecar injection
kubectl label namespace default istio-injection=enabled --overwrite
kubectl get namespace -L istio-injection

#deploy http-bin sample app
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/httpbin/httpbin.yaml

#configure a Gateway on port 80 for HTTP traffic https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/

kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: httpbin-gateway
spec:
  # The selector matches the ingress gateway pod labels.
  # If you installed Istio using Helm following the standard documentation, this would be "istio=ingress"
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
EOF

# Configure routes for traffic entering via the Gateway:
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: httpbin
spec:
  hosts:
  - "*"
  gateways:
  - httpbin-gateway
  http:
  - match:
    - uri:
        prefix: /status
    - uri:
        prefix: /delay
    route:
    - destination:
        port:
          number: 8000
        host: httpbin
EOF

# testing
export INGRESS_NAME=istio-ingressgateway
export INGRESS_NS=istio-ingress
kubectl get svc "$INGRESS_NAME" -n "$INGRESS_NS"

export INGRESS_HOST=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="http")].port}')
export SECURE_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
export TCP_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="tcp")].port}')

curl -s -I -HHost:httpbin.example.com "http://$INGRESS_HOST:$INGRESS_PORT/status/200"

## switch to internal LB
# change the YAML to annotated the Load Balancer to be internal https://istio.io/latest/docs/setup/additional-setup/gateway/
kubectl apply -f install-istio-gateway-int-lb.yaml

# log on to jumpbox to test using the internal IP

