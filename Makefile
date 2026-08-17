# hadoop-forge
#
# `make` with no target prints this list.

SHELL             := /bin/bash
.DEFAULT_GOAL     := help
.ONESHELL:

HADOOP_VERSION    ?= 3.3.6
COMPOSE           ?= docker compose
CLUSTER_FILE      := docker/docker-compose.yml
SINGLE_FILE       := docker/docker-compose.single.yml
MONITORING_FILE   := monitoring/docker-compose.monitoring.yml
DC                := $(COMPOSE) -f $(CLUSTER_FILE)
DC_SINGLE         := $(COMPOSE) -f $(SINGLE_FILE)
DC_MON            := $(COMPOSE) -f $(CLUSTER_FILE) -f $(MONITORING_FILE)

# Which topology `make shell`, `make smoke` and friends target.
# Overridable: make smoke TOPOLOGY=single
TOPOLOGY          ?= cluster
ifeq ($(TOPOLOGY),single)
ACTIVE_DC         := $(DC_SINGLE)
else
ACTIVE_DC         := $(DC)
endif

EXAMPLE_DIR       := examples/wordcount
EXAMPLE_JAR       := $(EXAMPLE_DIR)/target/wordcount-1.0.0.jar

export HADOOP_VERSION

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@printf '\n  Topology: \033[33m%s\033[0m (override with TOPOLOGY=single)\n' "$(TOPOLOGY)"

# ---------------------------------------------------------------------------
# Cluster lifecycle
# ---------------------------------------------------------------------------
.PHONY: build
build: ## Build the Hadoop image
	$(DC) build

.PHONY: up
up: ## Start the multi-node cluster (3 DataNodes, 2 NodeManagers)
	$(DC) up -d
	@$(MAKE) --no-print-directory wait
	@printf '\n  NameNode UI ........ http://localhost:9870\n'
	@printf '  ResourceManager UI . http://localhost:8088\n'
	@printf '  JobHistory UI ...... http://localhost:19888\n\n'

.PHONY: single
single: ## Start the pseudo-distributed cluster (one of each daemon)
	$(DC_SINGLE) up -d
	@$(MAKE) --no-print-directory wait TOPOLOGY=single

.PHONY: wait
wait: ## Block until the NameNode and ResourceManager report healthy
	@printf 'Waiting for the cluster to become healthy'
	@for i in $$(seq 1 60); do \
	  nn=$$($(ACTIVE_DC) ps --format json namenode 2>/dev/null | grep -o '"Health":"healthy"' || true); \
	  rm=$$($(ACTIVE_DC) ps --format json resourcemanager 2>/dev/null | grep -o '"Health":"healthy"' || true); \
	  if [[ -n "$$nn" && -n "$$rm" ]]; then printf ' ready\n'; exit 0; fi; \
	  printf '.'; sleep 5; \
	done; \
	printf '\n'; echo "Cluster did not become healthy in 5 minutes; check: make logs" >&2; exit 1

.PHONY: down
down: ## Stop the cluster, keeping HDFS data
	$(DC) down
	-$(DC_SINGLE) down

.PHONY: purge
purge: ## Stop the cluster and DELETE all HDFS data
	$(DC) down -v
	-$(DC_SINGLE) down -v

.PHONY: restart
restart: down up ## Restart the multi-node cluster

.PHONY: ps
ps: ## Show container and health status
	$(ACTIVE_DC) ps

.PHONY: logs
logs: ## Follow logs from every container
	$(ACTIVE_DC) logs -f --tail=100

.PHONY: shell
shell: ## Open a shell in the gateway (client) container
	$(ACTIVE_DC) exec gateway bash

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
.PHONY: health
health: ## Run the health report inside the cluster
	$(ACTIVE_DC) exec -T gateway bash /examples/../scripts/health-check.sh 2>/dev/null \
	  || $(ACTIVE_DC) exec -T namenode bash -c 'hdfs dfsadmin -report && yarn node -list'

.PHONY: smoke
smoke: ## End-to-end check: HDFS write/read plus a real MapReduce job
	$(ACTIVE_DC) exec -T gateway bash -s < scripts/smoke-test.sh

.PHONY: report
report: ## hdfs dfsadmin -report
	$(ACTIVE_DC) exec -T namenode hdfs dfsadmin -report

.PHONY: nodes
nodes: ## yarn node -list
	$(ACTIVE_DC) exec -T resourcemanager yarn node -list

# ---------------------------------------------------------------------------
# Examples
# ---------------------------------------------------------------------------
.PHONY: example
example: ## Build the WordCount jar with Maven
	cd $(EXAMPLE_DIR) && mvn -q -B clean package

.PHONY: wordcount
wordcount: ## Run the WordCount example on the running cluster
	$(ACTIVE_DC) exec -T gateway bash /examples/run-wordcount.sh

.PHONY: pi
pi: ## Run the bundled Pi estimator (CPU-bound cluster benchmark)
	$(ACTIVE_DC) exec -T gateway yarn jar \
	  /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-$(HADOOP_VERSION).jar \
	  pi 8 1000

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
.PHONY: monitoring-up
monitoring-up: ## Start the cluster with Prometheus and Grafana
	$(DC_MON) up -d
	@printf '\n  Prometheus ... http://localhost:9090\n  Grafana ...... http://localhost:3000 (admin/admin)\n\n'

.PHONY: monitoring-down
monitoring-down: ## Stop the monitoring stack
	$(DC_MON) down

# ---------------------------------------------------------------------------
# Quality gates — the same checks CI runs
# ---------------------------------------------------------------------------
.PHONY: lint
lint: lint-shell lint-docker lint-xml lint-links ## Run every linter

.PHONY: lint-shell
lint-shell: ## shellcheck every shell script
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed" >&2; exit 1; }
	shellcheck --severity=warning --external-sources \
	  scripts/*.sh scripts/lib/*.sh docker/*.sh conf/cluster/*.sh examples/*.sh

.PHONY: lint-docker
lint-docker: ## hadolint the Dockerfile
	docker run --rm -i hadolint/hadolint < docker/Dockerfile

.PHONY: lint-xml
lint-xml: ## Validate configuration XML
	bash tests/validate-configs.sh

.PHONY: lint-links
lint-links: ## Check that relative links in the Markdown resolve
	bash tests/check-links.sh

.PHONY: lint-compose
lint-compose: ## Validate the Compose files
	$(DC) config -q
	$(DC_SINGLE) config -q

.PHONY: test
test: lint-xml ## Run the config validation and example unit tests
	cd $(EXAMPLE_DIR) && mvn -q -B test

.PHONY: clean
clean: ## Remove build output
	-cd $(EXAMPLE_DIR) && mvn -q -B clean
	rm -rf $(EXAMPLE_DIR)/target
