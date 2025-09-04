
# Configurable variables (override on CLI, e.g. make addons ADDON_TAGS="argo")
INVENTORY ?= inventories/prod/hosts.ini
PLAYBOOK_PLATFORM ?= playbooks/platform.yml
PLAYBOOK_SITE ?= playbooks/site.yml
PLAYBOOK_CHECKS ?= playbooks/checks.yml

BOOTSTRAP_TAGS ?= host_base,k3s,metallb,ingress,cert_manager,registry,storage
ADDON_TAGS ?= monitoring,argo,outputs

install:
	ansible-galaxy install -r requirements.yml

lint:
	ansible-lint

syntax:
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK_SITE) --syntax-check

bootstrap:
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK_PLATFORM) --tags $(BOOTSTRAP_TAGS)

addons:
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK_PLATFORM) --tags $(ADDON_TAGS)

checks:
	ansible-playbook -i $(INVENTORY) $(PLAYBOOK_CHECKS)
