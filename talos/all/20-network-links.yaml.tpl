# Node networking as Talos 1.14 typed network documents. Matches the running
# cluster: the MAC-matched link is aliased to a stable name (ethSel0) and the
# static address, MTU, route and (on control-plane nodes) the shared Layer-2
# VIP are assigned directly to it. No bond is used, matching what Cilium
# currently binds to.
---
apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("{{ .Node.Data.macAddr }}", mac(link.hardware_addr))
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
mtu: 1500
addresses:
  - address: "{{ .Node.IP }}/24"
routes:
  - gateway: 192.168.5.1
{{- if eq .Node.Role "control-plane" }}
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
name: 192.168.5.254
link: ethSel0
{{- end }}
