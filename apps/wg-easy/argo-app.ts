import { Construct } from 'constructs'
import { App, Chart, ChartProps } from 'cdk8s'
import utils from '@repo/cdk8s-utils'

export class MyChart extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)

    utils.createArgoApp(this, id, {
      name: 'wg-easy'
    })
  }
}

const app = new App()
new MyChart(app, 'argo-wg-easy', { disableResourceNameHashes: true })
app.synth()
