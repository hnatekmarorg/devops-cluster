#!/bin/bash
kubectl create secret generic -n sops --from-file=key=$(realpath ~/age/key.txt)  sops-age-key-file
