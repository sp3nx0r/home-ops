* apply talos sysctl changes

  task configure
  talosctl apply-config -n 192.168.5.50 -f talos/clusterconfig/kubernetes-miirym.yaml
  talosctl apply-config -n 192.168.5.51 -f talos/clusterconfig/kubernetes-palarandusk.yaml
  talosctl apply-config -n 192.168.5.52 -f talos/clusterconfig/kubernetes-aurinax.yaml

*
