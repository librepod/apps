import { Construct } from 'constructs'
import {
  ArgocdApplication,
  ApplicationSpecSource,
  ApplicationSpecSources,
  ArgocdApplicationProps,
  ApplicationSpecInfo,
} from '@repo/cdk8s-imports/imports/argoproj.io'

const APP_NAMESPACE = 'argocd'
const APP_PROJECT = 'default'
const REPO_URL = 'https://github.com/librepod/apps'
const TARGET_REVISION = 'HEAD'

interface CreateArgoAppInput {
  name: string
  appNamespace?: string
  destinationNamespace?: string
  project?: string
  source?: Partial<ApplicationSpecSource>
  sources?: ApplicationSpecSources[]
  info?: ApplicationSpecInfo[]
}

export function createArgoApp(scope: Construct, id: string, input: CreateArgoAppInput) {
  const argoAppProps: ArgocdApplicationProps = {
    metadata: {
      finalizers: ['resources-finalizer.argocd.argoproj.io'],
      annotations: {
        'argocd.argoproj.io/sync-wave': '0'
      },
      name: input.name,
      namespace: input.appNamespace || APP_NAMESPACE
    },
    spec: {
      ignoreDifferences: [
        {
          group: 'argoproj.io',
          jsonPointers: ['/status'],
          kind: 'Application'
        }
      ],
      project: input.project || APP_PROJECT,
      destination: {
        namespace: input.destinationNamespace || input.name,
        server: 'https://kubernetes.default.svc'
      },
      syncPolicy: {
        syncOptions: ['CreateNamespace=true'],
        automated: {
          allowEmpty: true,
          prune: true,
          selfHeal: true
        }
      },
      info: input.info
    }
  }

  // Make sure that we have sources provided
  // if (!input.source && !input.sources) {
  //   throw new Error('Neither "source" nor "sources" are provided')
  // }

  if (input.sources) {
    (argoAppProps.spec as any).sources = input.sources
  } else {
    (argoAppProps.spec as any).source = {
      ...{
        repoUrl: REPO_URL,
        targetRevision: TARGET_REVISION,
        path: `apps/${input.name}`
      },
      ...input.source
    }
  }

  const app = new ArgocdApplication(scope, id, argoAppProps)
  return app
}
