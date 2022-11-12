SHELL = /bin/sh
.DELETE_ON_ERROR:

VENDOR ?= ajrass
PROJECT ?= egy-radius-cloud

//COMMITID = $(shell git rev-parse --short HEAD | tr -d '\n')$(shell git diff-files --quiet || printf -- -dirty)

PACKER_VERSION = 1.6.5
PACKER_BUILD_FLAGS += -var vendor=$(VENDOR) -var project=$(PROJECT) -var commit=$(COMMITID)

KERNEL = $(shell uname -s | tr A-Z a-z)
ifeq ($(shell uname -m),x86_64)
MACHINE = amd64
else
MACHINE = 386
endif

CLEAN =
DISTCLEAN =

.PHONY: all
all: dev

.PHONY: clean
clean:
	rm -rf $(CLEAN)

.PHONY: distclean
distclean: clean
	rm -rf $(DISTCLEAN)

.PHONY: notdirty
notdirty:
ifneq ($(findstring -dirty,$(COMMITID)),)
ifeq ($(IDDQD),)
	@{ echo 'DIRTY DEPLOYS FORBIDDEN, REJECTING DEPLOY DUE TO UNCOMMITED CHANGES' >&2; git status; exit 1; }
else
	@echo 'DIRTY DEPLOY BUT GOD MODE ENABLED' >&2
endif
endif

.PHONY: dev
# https://github.com/Microsoft/WSL/issues/423
ifeq ($(findstring microsoft,$(shell uname -r)),)
dev: CGROUP_RO=$(:ro)
endif
dev: docker
	-docker run -it --rm \
		--name egy-radius-cloud \
		-e container=docker \
		--sysctl net.ipv4.udp_rmem_min=$$((256 * 1024)) \
		-v $(CURDIR)/freeradius:/opt/$(VENDOR)/$(PROJECT)/freeradius:ro \
		-v $(CURDIR)/nginx:/opt/$(VENDOR)/$(PROJECT)/nginx:ro \
		-v $(CURDIR)/mysql:/opt/$(VENDOR)/$(PROJECT)/mysql:ro \
		-v $(CURDIR)/public:/opt/$(VENDOR)/$(PROJECT)/public:ro \
		$(foreach P,1812 1813 2083 3799,--publish=$(P):$(P)/udp --publish=$(P):$(P)/tcp) \
		--publish 3306:3306/tcp \
		--publish 80:80/tcp \
		--tmpfs /run \
		-v /sys/fs/cgroup:/sys/fs/cgroup$(CGROUP_RO) \
		--security-opt apparmor=unconfined \
		--cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add SYS_PTRACE \
		--stop-signal SIGPWR \
		$(VENDOR)/$(PROJECT):latest

.PHONY: docker
docker: packer.json .stamp.packer
	[ -n "$$(docker images -q $(VENDOR)/$(PROJECT))" ] \
		|| env TMPDIR=$(CURDIR) $(CURDIR)/packer build -on-error=ask -only docker $(PACKER_BUILD_FLAGS) $<

.PHONY: deploy-local
deploy-local:
ifneq ($(shell id -u),0)
	@{ echo you need to run this as root >&2; exit 1; }
endif
	git bundle create /tmp/$(VENDOR)-$(PROJECT).git HEAD
	env VENDOR=$(VENDOR) PROJECT=$(PROJECT) PACKER_BUILDER_TYPE=null /bin/sh $(CURDIR)/setup

SSH_USER ?= $(USER)
.PHONY: deploy-remote
deploy-remote: packer.json .stamp.packer
ifeq ($(SSH_HOST),)
	@{ echo you need to supply SSH_HOST >&2; exit 1; }
endif
ifeq ($(SSH_USER),)
	@{ echo you need to supply SSH_USER >&2; exit 1; }
endif
	env TMPDIR=$(CURDIR) $(CURDIR)/packer build -on-error=abort -only null $(PACKER_BUILD_FLAGS) \
		-var ssh_host=$(SSH_HOST) -var ssh_user=$(SSH_USER) $<

packer_$(PACKER_VERSION)_$(KERNEL)_$(MACHINE).zip:
	curl -f -O -J -L https://releases.hashicorp.com/packer/$(PACKER_VERSION)/$@
DISTCLEAN += $(wildcard packer_*.zip)

packer: packer_$(PACKER_VERSION)_$(KERNEL)_$(MACHINE).zip
	unzip -oDD $< $@
DISTCLEAN += packer

.stamp.packer: packer.json packer Makefile
	./packer validate $(PACKER_BUILD_FLAGS) $<
	@touch $@
CLEAN += .stamp.packer
