.PHONY: validate help
help:
	@echo "CI fetches openSUSE NEMO from OBS. Local: make validate only."
validate:
	./scripts/validate-recipe.sh
