import { test, expect, describe } from 'bun:test';
import { ArgoSystemApps, ArgoUserApps, ArgoProjects } from './main'
import { Testing } from 'cdk8s';

describe('ArgoProjects', () => {
  test('synth', () => {
    const app = Testing.app()
    const chart = new ArgoProjects(app, 'test-projects')
    const results = Testing.synth(chart)
    expect(results).toMatchSnapshot()
  })
})

describe('ArgoSystemApps', () => {
  test('synth', () => {
    const app = Testing.app()
    const chart = new ArgoSystemApps(app, 'test-system-apps')
    const results = Testing.synth(chart)
    expect(results).toMatchSnapshot()
  })
})

describe('ArgoUserApps', () => {
  test('synth', () => {
    const app = Testing.app()
    const chart = new ArgoUserApps(app, 'test-user-apps')
    const results = Testing.synth(chart)
    expect(results).toMatchSnapshot()
  })
})
