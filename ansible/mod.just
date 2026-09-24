set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

venv := justfile_directory() + '/.venv'
play := venv + '/bin/ansible-playbook'

[doc('Create venv and install Ansible + collections')]
[group('ansible')]
init:
    uv venv --allow-existing "{{ venv }}"
    uv pip install --python "{{ venv }}/bin/python" ansible-core ansible-lint boto3 botocore
    "{{ venv }}/bin/ansible-galaxy" collection install -r requirements.yml --force
    # Patch arensb.truenas 1.14.4 — remove broken filesystem action plugin
    rm -f ~/.ansible/collections/ansible_collections/arensb/truenas/plugins/action/filesystem.py

[doc('Lint Ansible playbooks and roles')]
[group('ansible')]
lint:
    "{{ venv }}/bin/ansible-lint"

[doc('Run all infrastructure configuration playbooks')]
[group('ansible')]
all: nas ms-s1 backblaze

[doc('Dry run all infrastructure configuration playbooks')]
[group('ansible')]
all-dry-run: nas-dry-run ms-s1-dry-run backblaze-dry-run

[doc('Run TrueNAS NAS (hl8) configuration playbook')]
[group('ansible')]
nas *args:
    "{{ play }}" playbooks/truenas-configure.yml {{ args }}

[doc('Dry run TrueNAS NAS (hl8) configuration playbook')]
[group('ansible')]
nas-dry-run *args:
    "{{ play }}" playbooks/truenas-configure.yml --check --diff {{ args }}

[doc('Unlock encrypted datasets after reboot')]
[group('ansible')]
nas-unlock *args:
    "{{ play }}" playbooks/truenas-unlock.yml {{ args }}

[doc('Scale down iSCSI workloads before NAS maintenance')]
[group('ansible')]
iscsi-drain *args:
    "{{ play }}" playbooks/iscsi-restart-pods.yml -e maintenance_mode=drain {{ args }}

[doc('Scale iSCSI workloads back up after NAS maintenance')]
[group('ansible')]
iscsi-restore *args:
    "{{ play }}" playbooks/iscsi-restart-pods.yml -e maintenance_mode=restore {{ args }}

[doc('Drain and restore iSCSI workloads in one pass (post-outage recovery)')]
[group('ansible')]
iscsi-restart *args:
    "{{ play }}" playbooks/iscsi-restart-pods.yml -e maintenance_mode=full {{ args }}

[doc('Scrub zero-byte Kopia index files from VolSync cache PVCs')]
[group('ansible')]
volsync-cache-scrub *args:
    "{{ play }}" playbooks/volsync-cache-scrub.yml {{ args }}

[doc('Run MS-S1 (sardior) configuration playbook')]
[group('ansible')]
ms-s1 *args:
    "{{ play }}" playbooks/ms-s1-configure.yml {{ args }}

[doc('Dry run MS-S1 (sardior) configuration playbook')]
[group('ansible')]
ms-s1-dry-run *args:
    "{{ play }}" playbooks/ms-s1-configure.yml --check --diff {{ args }}

[doc('Configure Backblaze B2 buckets (versioning + lifecycle)')]
[group('ansible')]
backblaze *args:
    "{{ play }}" playbooks/backblaze-configure.yml {{ args }}

[doc('Dry run Backblaze B2 bucket configuration')]
[group('ansible')]
backblaze-dry-run *args:
    "{{ play }}" playbooks/backblaze-configure.yml --check --diff {{ args }}

[doc('Purge noncurrent B2 object versions (dry-run by default)')]
[group('ansible')]
backblaze-purge-versions *args:
    "{{ play }}" playbooks/backblaze-purge-versions.yml {{ args }}

[doc('Delete all B2 object versions/markers under a prefix (dry-run by default)')]
[group('ansible')]
backblaze-delete-prefix *args:
    "{{ play }}" playbooks/backblaze-delete-prefix.yml {{ args }}
