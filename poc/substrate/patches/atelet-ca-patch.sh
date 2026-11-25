#!/bin/sh
# 给 atelet 挂上含自建 CA 的根证书（否则它的 imageCache 拉不到私有 registry 里的 actor 镜像）
kubectl -n ate-system create configmap poc-registry-ca \
  --from-file=ca-certificates.crt=/etc/ssl/certs/ca-certificates.crt
kubectl -n ate-system patch ds atelet --type=json -p '[
 {"op":"add","path":"/spec/template/spec/volumes/0","value":{"name":"registry-ca","configMap":{"name":"poc-registry-ca"}}},
 {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/0","value":{"name":"registry-ca","mountPath":"/etc/ssl/certs/ca-certificates.crt","subPath":"ca-certificates.crt","readOnly":true}},
 {"op":"add","path":"/spec/template/spec/initContainers/0/volumeMounts/0","value":{"name":"registry-ca","mountPath":"/etc/ssl/certs/ca-certificates.crt","subPath":"ca-certificates.crt","readOnly":true}}]'
