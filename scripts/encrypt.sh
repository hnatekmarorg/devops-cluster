#!/bin/bash

for file in ./secrets/*.yaml
do
  filename=$(basename "$file")
  echo $filename
  sops --age $(cat ~/age/public.txt) --encrypted-suffix='Templates' -e $(realpath $file) > ./devops/argocd/secrets/enc.$filename
done