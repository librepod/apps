import { App } from 'cdk8s'

import { ArgoProjectsChart } from './projects'
import { ArgoSystemAppsChart } from './system-apps'
import { ArgoUserAppsChart } from './user-apps'

// Projects
const argoProjects = new App()
new ArgoProjectsChart(argoProjects, 'projects', { disableResourceNameHashes: true })
argoProjects.synth()

// System Apps
const argoSystemApps = new App()
new ArgoSystemAppsChart(argoSystemApps, 'librepod-system-apps', { disableResourceNameHashes: true })
argoSystemApps.synth()

// User Apps
const argoUserApps = new App()
new ArgoUserAppsChart(argoUserApps, 'librepod-user-apps', { disableResourceNameHashes: true })
argoUserApps.synth()
