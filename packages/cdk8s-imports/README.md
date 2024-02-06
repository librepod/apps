 `@turbo/cdk8s-imports`

Collection of internal cdk8s imports.

## Import ArgoCD CRDs
NOTE: For some unknown reason the command `cdk8s import github:argoproj/argo-cd@v2.10.0`
fails with an error, so we have to workaround that with the following script:  
```shell
argocd_version=v2.10.0

echo "---" > argoproj.io_crd.yaml
curl https://raw.githubusercontent.com/argoproj/argo-cd/$argocd_version/manifests/crds/application-crd.yaml >> argoproj.io_crd.yaml
echo "---" >> argoproj.io_crd.yaml
curl https://raw.githubusercontent.com/argoproj/argo-cd/$argocd_version/manifests/crds/applicationset-crd.yaml >> argoproj.io_crd.yaml
echo "---" >> argoproj.io_crd.yaml
cdk8s import https://raw.githubusercontent.com/argoproj/argo-cd/$argocd_version/manifests/crds/appproject-crd.yaml >> argoproj.io_crd.yaml

cdk8s import argoproj.io_crd.yaml --class-prefix Argocd
rm argoproj.io_crd.yaml
```
