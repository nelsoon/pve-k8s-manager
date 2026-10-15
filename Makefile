PACKAGE := pve-k8s-manager
VERSION := 0.0.0-1
BUILD   := build
STAGE   := $(BUILD)/stage
DEB     := $(BUILD)/$(PACKAGE)_$(VERSION)_all.deb

PERL_FILES := $(shell find PVE -name '*.pm')
JS_FILES   := $(shell find www -name '*.js')

.PHONY: all lint test deb clean

all: lint deb

lint:
	@for f in $(PERL_FILES); do perl -I. -Itests/stubs -c $$f || exit 1; done
	@for f in $(JS_FILES); do node --check $$f || exit 1; done
	@echo "lint ok: $(words $(PERL_FILES)) perl modules, $(words $(JS_FILES)) js files"

test: lint deb
	@dpkg-deb -I $(DEB) | grep -q "Package: $(PACKAGE)" && echo "deb ok: $(DEB)"

# Skeleton packaging: stage the payload and build with dpkg-deb.
# A full debhelper build replaces this in Increment 4 (T4.3).
deb:
	@mkdir -p $(STAGE)/DEBIAN $(STAGE)/usr/share/perl5 $(STAGE)/usr/share/pve-manager/js
	@cp -r PVE $(STAGE)/usr/share/perl5/
	@cp www/manager6/*.js $(STAGE)/usr/share/pve-manager/js/
	@printf 'Package: $(PACKAGE)\nVersion: $(VERSION)\nArchitecture: all\nMaintainer: pve-k8s contributors\nDescription: Kubernetes cluster management for Proxmox VE\n Provisions and manages kubeadm Kubernetes clusters on Proxmox\n VMs from the Proxmox web UI, using Proxmox SDN and storage.\n' > $(STAGE)/DEBIAN/control
	@dpkg-deb --root-owner-group --build $(STAGE) $(DEB) >/dev/null
	@echo "built $(DEB)"

clean:
	@rm -rf $(BUILD)
