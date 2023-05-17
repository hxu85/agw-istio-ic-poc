#Prerequisites - see https://learn.microsoft.com/en-us/azure/aks/istio-deploy-addon

export CLUSTER=aks-agw-istio-ao-poc
export RESOURCE_GROUP=rg-agw-istio-ao-poc
export LOCATION=eastus

az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

#Install Istio add-on at the time of cluster creation 
az aks create \
--resource-group ${RESOURCE_GROUP} \
--name ${CLUSTER} \
--enable-asm \
--generate-ssh-keys

#ssh key files '/home/hxu/.ssh/id_rsa' and '/home/hxu/.ssh/id_rsa.pub'

# verify successul installation
az aks show --resource-group ${RESOURCE_GROUP} --name ${CLUSTER}  --query 'serviceMeshProfile.mode'
az aks get-credentials --resource-group ${RESOURCE_GROUP} --name ${CLUSTER}
kubectl get pods -n aks-istio-system

#enable sidecar injection
kubectl label namespace default istio.io/rev=asm-1-17


#deploy sample application from istio
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/bookinfo/platform/kube/bookinfo.yaml

#verify services & pods
kubectl get services
kubectl get pods


#enable internal istio ingress gateway

az aks mesh enable-ingress-gateway --resource-group ${RESOURCE_GROUP} --name ${CLUSTER} --ingress-gateway-type internal

kubectl get svc aks-istio-ingressgateway-internal -n aks-istio-ingress


#map apps to istio ingress gateway

kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: bookinfo-internal-gateway
spec:
  selector:
    istio: aks-istio-ingressgateway-internal
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: bookinfo-vs-internal
spec:
  hosts:
  - "*"
  gateways:
  - bookinfo-internal-gateway
  http:
  - match:
    - uri:
        exact: /productpage
    - uri:
        prefix: /static
    - uri:
        exact: /login
    - uri:
        exact: /logout
    - uri:
        prefix: /api/v1/products
    route:
    - destination:
        host: productpage
        port:
          number: 9080
EOF

#test the sample app

export INGRESS_HOST_INTERNAL=$(kubectl -n aks-istio-ingress get service aks-istio-ingressgateway-internal -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT_INTERNAL=$(kubectl -n aks-istio-ingress get service aks-istio-ingressgateway-internal -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export GATEWAY_URL_INTERNAL=$INGRESS_HOST_INTERNAL:$INGRESS_PORT_INTERNAL

# app not acessible from outside cluster's vnet yet
curl -s "http://${GATEWAY_URL_INTERNAL}/productpage" | grep -o "<title>.*</title>"

#app accessibnle from inside the cluster's vnet

kubectl exec "$(kubectl get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}')" -c ratings -- curl -sS  "http://$GATEWAY_URL_INTERNAL/productpage"  | grep -o "<title>.*</title>"

