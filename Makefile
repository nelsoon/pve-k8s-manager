PACKAGE := pve-k8s-manager
VERSION := 0.1.0-1
BUILD   := build
STAGE   := $(BUILD)/stage
DEB     := $(BUILD)/$(PACKAGE)_$(VERSION)_all.deb

PERL_FILES := $(shell find PVE -name '*.pm')
JS_FILES   := $(shell find www -name '*.js')

.PHONY: all lint test deb clean

all: lint deb

lint:
	@awk 'length>100{print FILENAME":"FNR": "length" columns"; bad=1} END{exit bad}' $(PERL_FILES)
	@for f in $(PERL_FILES); do perl -I. -Itests/stubs -c $$f || exit 1; done
	@for f in $(JS_FILES); do node --check $$f || exit 1; done
	@echo "lint ok: $(words $(PERL_FILES)) perl modules, $(words $(JS_FILES)) js files"

test: lint deb
	@perl -I. -Itests/stubs tests/unit/provision-kubeadm.t
	@perl -I. -Itests/stubs tests/unit/template-recipe.t
	@perl -I. -Itests/stubs tests/unit/ui-k8s.t
	@perl -I. -Itests/stubs tests/unit/pools-placement.t
	@perl -I. -Itests/stubs tests/unit/roll-upgrade.t
	@perl -I. -Itests/stubs tests/unit/supported-versions.t
	@perl -I. -Itests/stubs tests/unit/scaler.t
	@perl -I. -Itests/stubs tests/unit/addons.t
	@perl -I. -Itests/stubs tests/unit/evacuate.t
	@perl -I. -Itests/stubs tests/unit/network-t34.t
	@perl -I. -Itests/stubs tests/unit/storage-t36a.t
	@perl -I. -Itests/stubs tests/unit/volumes-t36b.t
	@perl -I. -Itests/stubs tests/unit/delete-orphan-audit.t
	@perl -I. -Itests/stubs tests/unit/update-options.t
	@perl -I. -Itests/stubs tests/unit/roll-rev-floor.t
	@perl -I. -Itests/stubs tests/unit/converge-nodes.t
	@perl -I. -Itests/stubs tests/unit/no-forward-lexical.t
	@perl -I. -Itests/stubs tests/unit/kube-vip-lease.t
	@perl -I. -Itests/stubs tests/unit/reuse-template-guard.t
	@perl -I. -Itests/stubs tests/unit/scaler-standdown.t
	@perl -I. -Itests/stubs tests/unit/surge-cp-ip.t
	@perl -I. -Itests/stubs tests/unit/roll-plan.t
	@perl -I. -Itests/stubs tests/unit/packaging.t
	@perl -I. -Itests/stubs tests/unit/upgrade-apply-skip.t
	@dpkg-deb -I $(DEB) | grep -q "Package: $(PACKAGE)" && echo "deb ok: $(DEB)"

# Packaging: stage the payload and build with dpkg-deb.
# Maintainer scripts are real (debian/postinst.*, postrm.*,
# integrate.pl); a debhelper flow can replace the staging
# later without changing them.
deb:
	@mkdir -p $(STAGE)/DEBIAN $(STAGE)/usr/share/perl5 $(STAGE)/usr/share/pve-manager/js
	@mkdir -p $(STAGE)/usr/sbin $(STAGE)/lib/systemd/system
	@cp -r PVE $(STAGE)/usr/share/perl5/
	@cp www/manager6/*.js $(STAGE)/usr/share/pve-manager/js/
	@install -m 0755 tools/pve-k8s-scaler $(STAGE)/usr/sbin/pve-k8s-scaler
	@install -m 0755 tools/pve-k8s-backup $(STAGE)/usr/sbin/pve-k8s-backup
	@cp systemd/pve-k8s-scaler.service systemd/pve-k8s-scaler.timer \
		systemd/pve-k8s-backup.service systemd/pve-k8s-backup.timer \
		$(STAGE)/lib/systemd/system/
	@mkdir -p $(STAGE)/etc/sysctl.d
	@install -m 0644 systemd/99-pve-k8s-vrf.conf \
		$(STAGE)/etc/sysctl.d/99-pve-k8s-vrf.conf
	@cat debian/postinst.head debian/integrate.pl \
		debian/postinst.tail > $(STAGE)/DEBIAN/postinst
	@cat debian/postrm.head debian/integrate.pl \
		debian/postrm.tail > $(STAGE)/DEBIAN/postrm
	@chmod 0755 $(STAGE)/DEBIAN/postinst $(STAGE)/DEBIAN/postrm
	@printf 'Package: $(PACKAGE)\nVersion: $(VERSION)\nArchitecture: all\nMaintainer: pve-k8s contributors\nDepends: pve-manager, perl\nDescription: Kubernetes cluster management for Proxmox VE\n Provisions and manages kubeadm Kubernetes clusters on Proxmox\n VMs from the Proxmox web UI, using Proxmox SDN and storage.\n' > $(STAGE)/DEBIAN/control
	@dpkg-deb --root-owner-group --build $(STAGE) $(DEB) >/dev/null
	@echo "built $(DEB)"

clean:
	@rm -rf $(BUILD)
