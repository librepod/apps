import { Construct } from 'constructs'
import { App, Chart, ChartProps, YamlOutputType } from 'cdk8s'
import { createArgoProject } from './lib'

/**
  *
  * ArgoCD Projects
  *
  */
export class ArgoProjectsChart extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)
    const projects = [
      { name: 'librepod-system', description: 'LibrePod System Apps' },
      { name: 'librepod-apps', description: 'LibrePod User Apps' },
    ]
    for (const p of projects) {
      createArgoProject(this, p.name, { spec: { description: p.description } })
    }
  }
}
