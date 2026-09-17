#!/bin/bash
kubectl create secret generic -n sops --from-file=key=$(realpath ~/age/key.txt)  sops-age-key-file
#kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml