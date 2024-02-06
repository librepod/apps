import * as kplus from 'cdk8s-plus-26'
import { Construct } from 'constructs'
import { Duration, Size } from 'cdk8s'
import { PersistentVolumeAccessMode } from 'cdk8s-plus-26'

const wgPort = 51820
const httpPort = 51821

export default function(scope: Construct) {
  const cm = new kplus.ConfigMap(scope, 'cm');
  cm.addData('PASSWORD', 'admin')
  cm.addData('WG_HOST', 'ee.relay.librepod.org')
  cm.addData('WG_PORT', '6000')
  cm.addData('WG_MTU', '1280')
  cm.addData('WG_DEFAULT_ADDRESS', '10.6.0.x')
  cm.addData('WG_DEFAULT_DNS', '192.168.2.167')

  const deploy = new kplus.Deployment(scope, 'Deployment', {
    replicas: 1,
    securityContext: {
      ensureNonRoot: false,
    },
  })

  const container = deploy.addContainer({
    image: 'ghcr.io/wg-easy/wg-easy:10',
    imagePullPolicy: kplus.ImagePullPolicy.ALWAYS,
    ports: [
      {
        name: 'http',
        number: httpPort,
        protocol: kplus.Protocol.TCP
      },
      {
        name: 'wg',
        number: wgPort,
        protocol: kplus.Protocol.UDP
      }
    ],
    readiness: kplus.Probe.fromTcpSocket({
      port: httpPort,
      initialDelaySeconds: Duration.seconds(5),
      timeoutSeconds: Duration.seconds(1),
      successThreshold: 1,
      periodSeconds: Duration.seconds(10),
      failureThreshold: 3,
    }),
    securityContext: {
      ensureNonRoot: false,
      readOnlyRootFilesystem: false,
      privileged: true,
      allowPrivilegeEscalation: true
    },
  })
  container.env.copyFrom(kplus.Env.fromConfigMap(cm));
  // container.env.addVariable('endpoint', kplus.EnvValue.fromValue('value'));
  // container.env.addVariable('endpoint', kplus.EnvValue.fromConfigMap(backendsConfig, 'endpoint'));
  // container.env.addVariable('password', kplus.EnvValue.fromSecretValue({ secret: credentials, key: 'password' }));

  const tunVolume = kplus.Volume.fromHostPath(scope, 'tun', 'tun', {
    path: '/dev/net/tun',
    type: kplus.HostPathVolumeType.CHAR_DEVICE
  })
  // create the storage request
  const pvc = new kplus.PersistentVolumeClaim(scope, 'pvc', {
    storage: Size.gibibytes(0.1),
    // SPecifying starage in mebibytes doesn't work as of now.
    // See issue: https://github.com/cdk8s-team/cdk8s-plus/issues/1950
    // storage: Size.mebibytes(100),
    storageClassName: 'nfs-client',
    accessModes: [PersistentVolumeAccessMode.READ_WRITE_MANY]
  })

  container.mount('/etc/wireguard', kplus.Volume.fromPersistentVolumeClaim(scope, 'pv', pvc))
  container.mount('/dev/net/tun', tunVolume)

  deploy.exposeViaService({
    ports: [
      {
        name: 'wg',
        protocol: kplus.Protocol.UDP,
        port: 51820,
        targetPort: wgPort,
      },
      {
        name: 'http',
        protocol: kplus.Protocol.TCP,
        port: 80,
        targetPort: httpPort,
      },
    ]
  })
  return deploy
}
