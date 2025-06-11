#!/bin/bash

for file in ./manifests/applications/enc.*.yaml
do
  filename=$(basename "$file" | sed "s/enc.//g")
  echo $filename
  sops --decrypt --encrypted-suffix='Templates' $file > ./manifests/secrets/$filename
done