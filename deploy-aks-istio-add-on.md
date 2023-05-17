# How to deploy AKS and Istio Add-on Behind an Application Gateway

This is based on Microsoft's documentation on the Istio Add-on for AKS: https://learn.microsoft.com/en-us/azure/aks/istio-deploy-addon

## Prerequisites 
 Refer to https://learn.microsoft.com/en-us/azure/aks/istio-deploy-addon for prerequists, chiefly registering new resource provider and installing neccessary tools.

## Create AKS with Istio Add-on

Set up environment variables
```
export CLUSTER=aks-agw-istio-ao-poc
export RESOURCE_GROUP=rg-agw-istio-ao-poc
export LOCATION=eastus`
```
Create resource group
```
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}
```

Install Istio add-on at the time of AKS cluster creation 
```
az aks create \
--resource-group ${RESOURCE_GROUP} \
--name ${CLUSTER} \
--enable-asm \
--generate-ssh-keys
```
*Note that --generate-ssh-keys is not mentioned in the documentation by is neccessary at the time of the writing to install the Add-on successfully*

Verify successul installation of AKS and Istio Add-on
```
az aks show --resource-group ${RESOURCE_GROUP} --name ${CLUSTER}  --query 'serviceMeshProfile.mode'
az aks get-credentials --resource-group ${RESOURCE_GROUP} --name ${CLUSTER}
kubectl get pods -n aks-istio-system
```

## Deploy Sample Application from Istio
Enable sidecar injection
```
kubectl label namespace default istio.io/rev=asm-1-17
```
Deploy sample application from istio
```
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/bookinfo/platform/kube/bookinfo.yaml
```
Verify application services & pods
```
kubectl get services
kubectl get pods
```

## Enable Internal Istio Ingress Gateway
Enable the Gateway
```
az aks mesh enable-ingress-gateway --resource-group ${RESOURCE_GROUP} --name ${CLUSTER} --ingress-gateway-type internal
```
Verify Instio Gateway services
```
kubectl get svc aks-istio-ingressgateway-internal -n aks-istio-ingress
```
Map the application services to istio ingress gateway
```
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
```

## Peer Hub vnet with the AKS vNet
create peering between the HibvNet where the App Gateway is to be deployed and the AKS vNet, per Microsoft documentation

## Test the sample app -internally
Set up environment variables
```
export INGRESS_HOST_INTERNAL=$(kubectl -n aks-istio-ingress get service aks-istio-ingressgateway-internal -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT_INTERNAL=$(kubectl -n aks-istio-ingress get service aks-istio-ingressgateway-internal -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export GATEWAY_URL_INTERNAL=$INGRESS_HOST_INTERNAL:$INGRESS_PORT_INTERNAL
```
Test that the application is not acessible from outside cluster's vnet yet
```
curl -s "http://${GATEWAY_URL_INTERNAL}/productpage" | grep -o "<title>.*</title>"
```
Test that the application is accessibnle from inside the cluster's vnet
```
kubectl exec "$(kubectl get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}')" -c ratings -- curl -sS  "http://$GATEWAY_URL_INTERNAL/productpage"  | grep -o "<title>.*</title>"
```

Test from a jumpbox VM that the product page is accessible via curl or web browser


## Install & Configure Application Gateway
Follow Microsoft's documentation to create an Application Gateway with WAF V2 if desired:
- Front end: public IP or both public and private IP, basic listener, port 8080
- Backend Pool: the external IP of the aks-istio-ingressgateway-internal LoadBalancer service
- Backend Setting: all default value
- Rule: bind frontend listerner to backend pool using the backend setting
- custom Health Probe: backend IP, port 80, /productpage
The goal is to pass through all traffic to the backend untouched, and let Istio manage the routing to the services in AKS

## Test the application - externally
Test the sample application through the app gateway
Open a browser and browse to `http://<appgateway url>:8080/productpage`