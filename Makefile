.PHONY: start show purge prep clean all

repo := $(shell git rev-parse --show-toplevel)
cur_dir := $(shell pwd)

start:
	echo "Starting Clean Up"

show:
	echo ${repo}; \
	echo ${cur_dir};

purge:
	find ${repo} -type f -name \*.tfstate.backup -exec rm {} \;
	find ${repo} -type f -name \*.tfstate -exec rm {} \;
	find ${repo} -type f -name \*.tfplan -exec rm {} \;
	find ${repo} -type d -name .terraform | xargs rm -rf {} \;

prep:
	find ${repo} -name \*.tf -exec chmod 644 {} \;
	find ${repo} -name \*.tfvars -exec chmod 644 {} \;
	find ${repo} -name \*.txt -exec chmod 644 {} \;

clean: start show purge

all: clean prep
