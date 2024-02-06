import merge from 'lodash.merge'
import { Construct } from 'constructs'
import {
  IngressRouteSpecRoutesKind,
  IngressRouteSpecRoutesServicesPort,
  IngressRouteUdpSpecRoutesServicesPort,
  TraefikIngressRoute,
  TraefikIngressRouteProps,
  TraefikIngressRouteUdp,
  TraefikIngressRouteUdpProps 
} from '@repo/cdk8s-imports'

export function createIngress(
  scope: Construct,
  name: string,
  props: Partial<TraefikIngressRouteProps> = {}
) {
  const defaultProps: TraefikIngressRouteProps = {
    metadata: {
      name: name,
    },
    spec: {
      entryPoints: [ "web", "websecure" ],
      routes: [
        {
          match: `Host(\`${name}.libre.pod\`)`,
          kind: IngressRouteSpecRoutesKind.RULE,
          priority: 1,
          services: [{
            // name: name,
            name: 'wg-easy-deployment-service',
            port: IngressRouteSpecRoutesServicesPort.fromNumber(80)
          }],
        }
      ],
      tls: { secretName: `tls-${name}` }
    }
  }

  // Merge default props and overrides
  const appProps = merge(defaultProps, props)

  return new TraefikIngressRoute(scope, name, appProps)
}

export function createIngressUdp(
  scope: Construct,
  name: string,
  port: number,
  props: Partial<TraefikIngressRouteUdpProps> = {}
) {
  const defaultProps: TraefikIngressRouteUdpProps = {
    metadata: {
      name: `${name}`,
    },
    spec: {
      entryPoints: [ "wireguard" ],
      routes: [
        {
          services: [{
            // name: `${name}`,
            name: 'wg-easy-deployment-service',
            port: IngressRouteUdpSpecRoutesServicesPort.fromNumber(port),
            weight: 10
          }]
        } 
      ]
    }
  }

  // Merge default props and overrides
  const appProps = merge(defaultProps, props)

  return new TraefikIngressRouteUdp(scope, name, appProps)
}
