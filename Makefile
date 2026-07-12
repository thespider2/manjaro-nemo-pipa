.PHONY: validate help

help:
	@echo "Builds run in CI only (GitHub Actions ubuntu-24.04-arm / CircleCI arm.large)."
	@echo "  make validate  - check profiles locally (no image build)"

validate:
	./scripts/validate-recipe.sh
