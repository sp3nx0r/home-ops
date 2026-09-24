# The typed KubeletConfig document cannot express extraMounts, and any
# machine.kubelet block conflicts with it. We need the iSCSI bind mounts for
# democratic-csi, so we delete the generated KubeletConfig document and keep
# the kubelet config in v1alpha1 form (this also matches the running cluster).
machine:
  kubelet:
    image: ghcr.io/siderolabs/kubelet:{{ .KubernetesVersion }}
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true
    extraConfig:
      crashLoopBackOff:
        maxContainerRestartPeriod: 60s
      imageMaximumGCAge: 168h
      maxParallelImagePulls: 3
      serializeImagePulls: false
    extraMounts:
      - destination: /etc/iscsi
        type: bind
        source: /etc/iscsi
        options:
          - bind
          - rshared
      - destination: /var/lib/iscsi
        type: bind
        source: /var/lib/iscsi
        options:
          - bind
          - rshared
---
apiVersion: v1alpha1
kind: KubeletConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeNodeConfig
nodeIP:
  validSubnets:
    - 192.168.5.0/24
