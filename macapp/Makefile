APP := AITL Bridge
DIST := dist
BUNDLE := $(DIST)/$(APP).app
.DEFAULT_GOAL := help
.PHONY: help build run install uninstall clean
help: ## Show this help
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;33m%-10s\033[0m %s\n", $$1, $$2}'
build: ## Build an ad-hoc-signed "AITL Bridge.app" into ./dist
	@bash scripts/build-app.sh
run: build ## Build and launch
	@pkill -x AITLBridge 2>/dev/null || true
	@open "$(BUNDLE)"
install: build ## Build, install into /Applications, launch
	@pkill -x AITLBridge 2>/dev/null || true
	@rm -rf "/Applications/$(APP).app"
	@cp -R "$(BUNDLE)" /Applications/
	@printf '\033[1;32m✓\033[0m Installed /Applications/$(APP).app\n'
	@open "/Applications/$(APP).app"
uninstall: ## Remove the app
	@pkill -x AITLBridge 2>/dev/null || true
	@rm -rf "/Applications/$(APP).app"
clean: ## Remove build products
	@rm -rf $(DIST) $(HOME)/.cache/aitl-build
