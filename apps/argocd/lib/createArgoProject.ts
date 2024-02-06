import { Construct } from 'constructs'
import { App, Chart, ChartProps } from 'cdk8s'
import merge from 'lodash.merge'

import {
  ArgocdAppProject,
  ArgocdAppProjectProps,
} from '@repo/cdk8s-imports'

const ARGOCD_NAMESPACE = 'argocd'
const DEFAULT_K8S_SERVER = 'https://kubernetes.default.svc'

export function createArgoProject(scope: Construct, name: string, projPropsOverrides: Partial<ArgocdAppProjectProps> = {}) {
  const defaultProjProps: ArgocdAppProjectProps = {
    metadata: {
      name,
      namespace: ARGOCD_NAMESPACE,
      annotations: {
        'argocd.argoproj.io/sync-options': 'PruneLast=true',
        'argocd.argoproj.io/sync-wave': '-5'
      }
    },
    spec: {
      description: 'LibrePod Project',
      destinations: [{
        namespace: '*',
        server: DEFAULT_K8S_SERVER
      }],
      clusterResourceWhitelist: [{
        group: '*', kind: '*'
      }],
      namespaceResourceWhitelist: [{
        group: '*', kind: '*'
      }],
      sourceRepos: ['*'],
    }
  }
  return new ArgocdAppProject(scope, name, merge(defaultProjProps, projPropsOverrides))
}
