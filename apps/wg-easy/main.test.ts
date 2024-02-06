import { test, expect, describe } from 'bun:test';
import { WgEasy } from './main'
import { Testing } from 'cdk8s'

describe('WgEasy', () => {
  test('synth', () => {
    const app = Testing.app()
    const chart = new WgEasy(app, 'test-chart')
    const results = Testing.synth(chart)
    expect(results).toMatchSnapshot()
  })
})
