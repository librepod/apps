import { name as appName, version } from './package.json'
import { Construct } from 'constructs'
import { Helm, App, Chart, ChartProps } from 'cdk8s'
import * as utils from '@repo/cdk8s-utils'

export class MyChart extends Chart {
  constructor(scope: Construct, id: string, props: ChartProps = {}) {
    super(scope, id, props)

    new Helm(this, appName, {
      repo: 'https://traefik.github.io/charts',
      chart: appName,
      namespace: appName,
      releaseName: appName,
      version: version,
      values: utils.parseValues('values.yaml')
    });
  }
}

const app = new App()
new MyChart(app, appName, { disableResourceNameHashes: true })
app.synth()
