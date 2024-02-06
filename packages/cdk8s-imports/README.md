 `@turbo/cdk8s-imports`

Collection of internal cdk8s imports.

## Import ArgoCD CRDs
NOTE: For some unknown reason the command `cdk8s import github:argoproj/argo-cd@v2.10.0`
fails with an error, so we have to workaround that with the following script:  
```shell
argocd_version=v2.10.0
argocd_crds=argoproj.io_crds.yaml
kustomize build https://github.com/argoproj/argo-cd.git/manifests/crds\?ref=$argocd_version > $argocd_crds
cdk8s import $argocd_crds --class-prefix Argocd
```

## Import Traefik CRDs
```shell
traefik_version=v26.1.0
traefik_crds=traefik.containo.us_crds.yaml
kustomize build https://github.com/traefik/traefik-helm-chart.git/traefik/crds\?ref=$traefik_version > $traefik_crds
cdk8s import $traefik_crds --class-prefix Traefik
```
