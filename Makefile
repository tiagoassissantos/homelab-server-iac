install:
	ansible-galaxy install -r requirements.yml

lint:
	ansible-lint

syntax:
	ansible-playbook -i inventories/prod/hosts.ini playbooks/site.yml --syntax-check

bootstrap:
	ansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml --tags host_base,k3s,metallb,ingress,cert_manager,registry,storage

addons:
	ansible-playbook -i inventories/prod/hosts.ini playbooks/platform.yml --tags monitoring,argo,outputs

checks:
	ansible-playbook -i inventories/prod/hosts.ini playbooks/checks.yml

