import { Construct } from 'constructs'
import { Chart, ChartProps } from 'cdk8s'
import { createArgoApp } from './lib'

/**
  *
  * ArgoCD User Applications
  *
  */
export class ArgoUserAppsChart extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)
    const apps: string[] = [
      'wg-easy'
    ]
    for (const appName of apps) {
      createArgoApp(this, appName, { spec: { project: 'librepod-apps' } })
    }
  }
}
