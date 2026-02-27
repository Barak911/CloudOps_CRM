.PHONY: help test e2e build lint helm-lint tf-validate tf-plan clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

test: ## Run unit tests
	cd app && pip install -r requirements-dev.txt -q && pytest test_app.py -v

e2e: ## Run E2E tests (starts docker compose)
	docker compose -f app/docker-compose.test.yml up -d
	@echo "Waiting for services..."
	@for i in $$(seq 1 30); do \
		curl -sf http://localhost:5001/health > /dev/null 2>&1 && break; \
		sleep 2; \
	done
	cd app && ./test_e2e.sh
	docker compose -f app/docker-compose.test.yml down -v

build: ## Build Docker image
	docker build -t crm-app:latest -f app/Dockerfile app/

helm-lint: ## Lint Helm chart
	helm lint k8s/crm-stack/

tf-validate: ## Validate Terraform configuration
	cd infra && terraform init -backend=false -input=false > /dev/null 2>&1 && terraform validate

tf-plan: ## Run Terraform plan (requires backend init)
	cd infra && terraform plan

clean: ## Remove caches and build artifacts
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	docker compose -f app/docker-compose.test.yml down -v 2>/dev/null || true
