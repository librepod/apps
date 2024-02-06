import { Construct } from 'constructs'
import { Chart, ChartProps } from 'cdk8s'
import { createArgoApp } from './lib'

/**
  *
  * ArgoCD System Applications
  *
  */
export class ArgoSystemAppsChart extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)
    const apps = [
      'traefik',
    ]
    for (const appName of apps) {
      createArgoApp(this, appName, { spec: { project: 'librepod-system' } })
    }
  }
}
