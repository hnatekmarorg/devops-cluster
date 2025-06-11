#!/bin/bash
kubectl create secret generic -n sops-operator --from-file=key=~/age/key.txt  sops-age-key-file
