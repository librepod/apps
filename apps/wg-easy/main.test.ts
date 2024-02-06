import { test, expect, describe } from 'bun:test';
import { MyChart } from './main'
import { Testing } from 'cdk8s'

describe('Chart', () => {
  test('synth', () => {
    const app = Testing.app()
    const chart = new MyChart(app, 'test-chart')
    const results = Testing.synth(chart)
    expect(results).toMatchSnapshot()
  })
})
