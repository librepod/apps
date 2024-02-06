import { Construct } from 'constructs'
import { App, Chart, ChartProps } from 'cdk8s'
import { ArgocdApplication } from '@repo/cdk8s-imports/imports/argoproj.io'

export class LibrePodApps extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)

    new ArgocdApplication(this, id, {
      metadata: {
        finalizers: ['resources-finalizer.argocd.argoproj.io'],
        annotations: {
          'argocd.argoproj.io/sync-wave': '0'
        },
        name: 'librepod-apps',
        namespace: 'argocd'
      },
      spec: {
        ignoreDifferences: [
          {
            group: 'argoproj.io',
            jsonPointers: ['/status'],
            kind: 'Application'
          }
        ],
        project: 'default',
        source: {
          repoUrl: 'https://github.com/librepod/apps',
          targetRevision: 'HEAD',
          path: 'apps/wg-easy',
          plugin: {
            name: 'cdk8s'
          }
        },
        destination: {
          namespace: 'wg-easy',
          server: 'https://kubernetes.default.svc'
        },
        syncPolicy: {
          syncOptions: [ 'CreateNamespace=true' ],
          automated: {
            allowEmpty: true,
            prune: true,
            selfHeal: true
          }
        }
      }
    })
  }
}

const app = new App()
new LibrePodApps(app, 'librepod-apps', { disableResourceNameHashes: true })
app.synth()
