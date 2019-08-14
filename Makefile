PERL=perl
RSYNC=rsync
PERL_VERSION=${shell ${PERL} -e 'print substr($$^V, 1)'}
PERL_MIN_VERSION=5.10
CPAN=cpan
CPANM=cpanm
SQITCH=sqitch
SQITCH_VERSION=${word 3,${shell ${SQITCH} --version}}
SQITCH_MIN_VERSION=0.97
GREP=grep
AWK=awk
PSQL=psql -h localhost
# "psql --version" prints "psql (PostgreSQL) XX.XX"
PSQL_VERSION=${word 3,${shell ${PSQL} --version}}
PG_SERVER_VERSION=${strip ${shell ${PSQL} -tc 'show server_version;' || echo error}}
PG_MIN_VERSION=9.1
PG_ROLE=${shell whoami}

SHELL := /usr/bin/env bash
PATHFINDER_PREFIX := wksv3k
PROJECT_PREFIX := cas-ggircs-

THIS_FILE := $(lastword $(MAKEFILE_LIST))
include .pipeline/*.mk

OC_TEMPLATE_VARS += METABASE_BRANCH=bcgov OC_PROJECT=${OC_PROJECT}

define check_file_in_path
	${if ${shell which ${word 1,${1}}},
		${info ✓ Found ${word 1,${1}}},
		${error ✖ No ${word 1,${1}} in path.}
	}
endef

define check_min_version_num
	${if ${shell printf '%s\n%s\n' "${3}" "${2}" | sort -CV || echo error},
		${error ✖ ${word 1,${1}} version needs to be at least ${3}.},
		${info ✓ ${word 1,${1}} version is at least ${3}.}
	}
endef

.PHONY: verify_installed
verify_installed:
	$(call check_file_in_path,${PERL})
	$(call check_min_version_num,${PERL},${PERL_VERSION},${PERL_MIN_VERSION})

	$(call check_file_in_path,${CPAN})
	$(call check_file_in_path,${GIT})
	$(call check_file_in_path,${RSYNC})

	$(call check_file_in_path,${PSQL})
	$(call check_min_version_num,${PSQL},${PSQL_VERSION},${PG_MIN_VERSION})
	@@echo ✓ External dependencies are installed

.PHONY: verify_pg_server
verify_pg_server:
ifeq (error,${PG_SERVER_VERSION})
	${error Error while connecting to postgres server}
else
	${info postgres is online}
endif

ifneq (${PSQL_VERSION}, ${PG_SERVER_VERSION})
	${error psql version (${PSQL_VERSION}) does not match the server version (${PG_SERVER_VERSION}) }
else
	${info psql and server versions match}
endif

ifeq (0,${shell ${PSQL} -qAtc "select count(*) from pg_user where usename='${PG_ROLE}' and usesuper=true"})
	${error A postgres role with the name "${PG_ROLE}" must exist and have the SUPERUSER privilege.}
else
	${info postgres role "${PG_ROLE}" has appropriate privileges}
endif

	@@echo ✓ PostgreSQL server is ready

.PHONY: verify
verify: verify_installed verify_pg_server

.PHONY: verify_ready
verify_ready:
	# ensure postgres is online
	@@${PSQL} -tc 'show server_version;' | ${AWK} '{print $$NF}';

.PHONY: verify
verify: verify_installed verify_ready

.PHONY: install_cpanm
install_cpanm:
ifeq (${shell which ${CPANM}},)
	# install cpanm
	@@${CPAN} App:cpanminus
endif

.PHONY: install_cpandeps
install_cpandeps:
	# install sqitch
	${CPANM} -n https://github.com/matthieu-foucault/sqitch/releases/download/v1.0.1.TRIAL/App-Sqitch-v1.0.1-TRIAL.tar.gz
	# install Perl dependencies from cpanfile
	${CPANM} --installdeps .

.PHONY: postinstall_check
postinstall_check:
	@@printf '%s\n%s\n' "${SQITCH_MIN_VERSION}" "${SQITCH_VERSION}" | sort -CV ||\
 	(echo "FATAL: ${SQITCH} version should be at least ${SQITCH_MIN_VERSION}. Make sure the ${SQITCH} executable installed by cpanminus is available has the highest priority in the PATH" && exit 1);

.PHONY: install
install: install_cpanm install_cpandeps postinstall_check

define switch_project
	@@echo ✓ logged in as: $(shell ${OC} whoami)
	@@${OC} project ${OC_PROJECT} >/dev/null
	@@echo ✓ switched project to: ${OC_PROJECT}
endef

define oc_process
	@@${OC} process -f openshift/${1}.yml ${2} | ${OC} apply --wait=true --overwrite=true -f-
endef

define oc_promote
	@@$(OC) tag $(OC_TOOLS_PROJECT)/$(1):$(2) $(1)-mirror:$(2) --reference-policy=local
endef

define build
	@@echo Add all image streams and build in the tools project...
	$(call oc_process,imagestream/cas-ggircs-python,)
	$(call oc_process,imagestream/cas-ggircs-ciip-2018-extract,)
	$(call oc_process,imagestream/cas-ggircs-ciip-2018-schema,)
	$(call oc_process,buildconfig/cas-ggircs-ciip-2018-extract,GIT_BRANCH=${GIT_BRANCH} GIT_BRANCH_NORM=${GIT_BRANCH_NORM})
	$(call oc_process,buildconfig/cas-ggircs-ciip-2018-schema,GIT_BRANCH=${GIT_BRANCH} GIT_BRANCH_NORM=${GIT_BRANCH_NORM})
endef

define deploy_extract
	$(call oc_process,imagestream/cas-ggircs-ciip-2018-extract-mirror)
	$(call oc_promote,cas-ggircs-ciip-2018-extract,${GIT_BRANCH_NORM})
	$(call oc_process,persistentvolumeclaim/cas-ggircs-ciip-2018-data,)
	$(call oc_process,deploymentconfig/cas-ggircs-ciip-2018-extract,GIT_BRANCH_NORM=${GIT_BRANCH_NORM})
endef

define deploy_schema
	$(call oc_process,imagestream/cas-ggircs-ciip-2018-schema-mirror)
	$(call oc_promote,cas-ggircs-ciip-2018-schema,${GIT_BRANCH_NORM})
	$(call oc_process,deploymentconfig/cas-ggircs-ciip-2018-schema,GIT_BRANCH_NORM=${GIT_BRANCH_NORM})
endef

.PHONY: deploy_tools
deploy_tools: OC_PROJECT=${OC_TOOLS_PROJECT}
deploy_tools:
	$(call switch_project)
	$(call build)

.PHONY: deploy_test_schema
deploy_test_schema: OC_PROJECT=${OC_TEST_PROJECT}
deploy_test_schema:
	$(call switch_project)
	$(call deploy_schema)

.PHONY: deploy_dev_schema
deploy_dev_schema: OC_PROJECT=${OC_DEV_PROJECT}
deploy_dev_schema:
	$(call switch_project)
	$(call deploy_schema)

define deploy_extract
	$(call oc_process,persistentvolumeclaim/cas-ggircs-ciip-2018-data)
	$(call oc_process,imagestream/cas-ggircs-ciip-2018-extract-mirror)
	$(call oc_promote,cas-ggircs-ciip-2018-extract,${GIT_BRANCH_NORM})
	$(call oc_process,deploymentconfig/cas-ggircs-ciip-2018-extract,GIT_BRANCH_NORM=${GIT_BRANCH_NORM})
endef

.PHONY: deploy_test_extract
deploy_test_extract: OC_PROJECT=${OC_TEST_PROJECT}
deploy_test_extract:
	$(call switch_project)
	$(call deploy_extract)

.PHONY: deploy_dev_extract
deploy_dev_extract: OC_PROJECT=${OC_DEV_PROJECT}
deploy_dev_extract:
	$(call switch_project)
	$(call deploy_schema)



.PHONY: help
help: $(call make_help,help,Explains how to use this Makefile)
	@@exit 0

.PHONY: targets
targets: $(call make_help,targets,Lists all targets in this Makefile)
	$(call make_list_targets,$(THIS_FILE))

.PHONY: whoami
whoami: $(call make_help,whoami,Prints the name of the user currently authenticated via `oc`)
	$(call oc_whoami)

.PHONY: project
project: whoami
project: $(call make_help,project,Switches to the desired $$OC_PROJECT namespace)
	$(call oc_project)

.PHONY: lint
lint: $(call make_help,lint,Checks the configured yml template definitions against the remote schema using the tools namespace)
lint: OC_PROJECT=$(OC_TOOLS_PROJECT)
lint: whoami
	$(call oc_lint)

.PHONY: configure
configure: $(call make_help,configure,Configures the tools project namespace for a build)
configure: OC_PROJECT=$(OC_TOOLS_PROJECT)
configure: whoami
	$(call oc_configure)

.PHONY: build
build: $(call make_help,build,Builds the source into an image in the tools project namespace)
build: OC_PROJECT=$(OC_TOOLS_PROJECT)
build: whoami
	$(call oc_build,$(PROJECT_PREFIX)metabase-build)
	$(call oc_build,$(PROJECT_PREFIX)metabase)

.PHONY: install
install: whoami
	$(call oc_promote,$(PROJECT_PREFIX)metabase)
