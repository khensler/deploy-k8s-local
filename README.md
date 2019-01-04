# deploy-k8s-local
Deploys Kubernetes cluster from scratch with metallb and ingress-nginx.

Requirements:
vcenter
powercli
ubuntu template

The script will pull  https://raw.githubusercontent.com/moron10321/deploy-k8s-local/master/layer2-config.yaml.  
You will need to customize this file and host it yourself to use a different IP range for external IPs

The kube conf file will be copied to the current directory named as the clustername.conf

Usage
```
.\k8-lc.ps1 -username <guest username> (-password <guest password> will prompt if not specifed) -nodes <number of nodes to add or remove> -clusterName <cluster-name> -clonefrom <template vm> -portGroup <portgroup to connect to> (-server <vcenter if not connected>) (-remove $true <removes nodes>) (-master $true <removes master and cluster>)
```
  
examples

1) Build a 3 node culster on an already connected vcenter (connect-viserver vcenter) from a template vm ubuntu-18.0.4-lts on the "VM Network" network
```
.\k8-lc.ps1 -username k8admin -nodes 3 -clusterName Test-Cluster -clonefrom ubuntu-18.0.4-lts -portGroup "VM Network"
```
2) Scale existing cluster Test-Cluster up by 3 nodes
```
.\k8-lc.ps1 -username k8admin -nodes 2 -clusterName Test-Cluster -clonefrom ubuntu-18.0.4-lts -portGroup "VM Network"
```
3) Scale existing cluster Test-Cluster down by 2 nodes
```
.\k8-lc.ps1 -username k8admin -nodes 2 -clusterName Test-Cluster -clonefrom ubuntu-18.0.4-lts -portGroup "VM Network" -remove $true
```
4) Delete cluster Test-Cluster
```
.\k8-lc.ps1 -username k8admin -nodes 3 -clusterName Test-Cluster -clonefrom ubuntu-18.0.4-lts -portGroup "VM Network" -remove $true -master $true
```
App deployment:

To deploy planspotter (https://github.com/yfauser/planespotter)

You may execute the following if you named your cluster Test-Cluster  Please note the frontend hostname foudn in https://raw.githubusercontent.com/moron10321/deploy-k8s-local/master/frontend-deployment_all_k8s.yaml
```
kubectl --kubeconfig=Test-Cluster.conf create ns planespotter
kubectl --kubeconfig=Test-Cluster.conf config set-context kubernetes-admin@kubernetes --namespace planespotter
kubectl --kubeconfig=Test-Cluster.conf create -f https://raw.githubusercontent.com/moron10321/deploy-k8s-local/master/mysql_pod.yaml
kubectl --kubeconfig=Test-Cluster.conf create -f https://raw.githubusercontent.com/yfauser/planespotter/master/kubernetes/app-server-deployment_all_k8s.yaml
kubectl --kubeconfig=Test-Cluster.conf create -f https://raw.githubusercontent.com/moron10321/deploy-k8s-local/master/frontend-deployment_all_k8s.yaml
kubectl --kubeconfig=Test-Cluster.conf create -f https://raw.githubusercontent.com/yfauser/planespotter/master/kubernetes/redis_and_adsb_sync_all_k8s.yaml
```

To find the LB IP:
```
kubectl --kubeconfig=Test-Cluster.conf get services --all-namespaces
```
