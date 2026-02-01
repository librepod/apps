# Seafile on LibrePod

## Deployment

Deploy with ArgoCD or kubectl:

```bash
kustomize build --enable-helm apps/seafile/overlays/librepod | kubectl apply -f -
```

## Access

- Web UI: https://seafile.libre.pod
- Default admin: admin@libre.pod / changeme_admin_password

**IMPORTANT:** Change passwords before production use!
