import { name as appName } from './package.json'
import { Construct } from 'constructs'
import { App, Chart, ChartProps } from 'cdk8s'

import { createIngress, createIngressUdp } from '@repo/cdk8s-utils'
import { createDeployment } from './lib/deployment'

export class MyChart extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)

    createDeployment(this)
    createIngress(this, `${appName}`)
    createIngressUdp(this, `${appName}-udp`, 51820)
  }
}

const app = new App()
new MyChart(app, appName, { disableResourceNameHashes: true })
app.synth()
