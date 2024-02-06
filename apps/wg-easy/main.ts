import { Construct } from 'constructs'
import { App, Chart, ChartProps } from 'cdk8s'

import createDeployment from './lib/deployment'

export class WgEasy extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)

    createDeployment(this)
  }
}

const app = new App()
new WgEasy(app, 'wg-easy', { disableResourceNameHashes: true })
app.synth()
