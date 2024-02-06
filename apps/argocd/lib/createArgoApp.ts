import { Construct } from 'constructs'
import merge from 'lodash.merge'

import {
  ArgocdApplication,
  ArgocdApplicationProps,
} from '@repo/cdk8s-imports'

const ARGOCD_NAMESPACE = 'argocd'
const APP_PROJECT = 'default'
const REPO_URL = 'https://github.com/librepod/apps'
const TARGET_REVISION = 'HEAD'
const DEFAULT_K8S_SERVER = 'https://kubernetes.default.svc'

export function createArgoApp(scope: Construct, name: string, appPropsOverrides: Partial<ArgocdApplicationProps> = {}) {
  const defaultAppProps: ArgocdApplicationProps = {
    metadata: {
      finalizers: ['resources-finalizer.argocd.argoproj.io'],
      annotations: {
        'argocd.argoproj.io/sync-wave': '0'
      },
      name: name,
      namespace: ARGOCD_NAMESPACE
    },
    spec: {
      ignoreDifferences: [
        {
          group: 'argoproj.io',
          jsonPointers: ['/status'],
          kind: 'Application'
        }
      ],
      project: APP_PROJECT,
      destination: {
        namespace: name,
        server: DEFAULT_K8S_SERVER
      },
      syncPolicy: {
        syncOptions: ['CreateNamespace=true'],
        automated: {
          allowEmpty: true,
          prune: true,
          selfHeal: true
        }
      },
      source: {
        repoUrl: REPO_URL,
        targetRevision: TARGET_REVISION,
        path: `apps/${name}`
      }
    }
  }

  // Merge default props and overrides
  const appProps = merge(defaultAppProps, appPropsOverrides)

  // Should be either source or sources
  if (appProps?.spec?.sources) {
    (appProps.spec.source as any) = null
  }

  return new ArgocdApplication(scope, name, appProps)
}
