SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: setup help deps test credo dialyzer coverage check format clean release publish-release publish-release-force setup-hooks setup-db reset-db logs git-push push-and-publish sync-release-version dispatch-test pre-push-cleanup

help:
	@echo "Dispatcher Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail server log with grc (auto-detected by repo name; make -C .. install-grc)"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	$(MIX) deps.get

test:
	@echo "Running test suite (8 test files)..."
	@echo "Expected: 1-2 minutes"
	@echo ""
	@time $(MIX) test

credo:
	$(MIX) credo

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo dialyzer
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/dispatcher_bot/"
	@echo ""

test-release-smoke:
	@echo "==============================================="
	@echo "Running release smoke test"
	@echo "==============================================="
	@RELEASE_NAME=dispatcher_bot NATS_SERVERS=nats://localhost:4224 \
		bash $(SCRIPTS_DIRECTORY)/test_release_smoke.sh

# Detect if branch touches responder, NATS consumer, or bridge envelope code.
# Used as a gate in publish-release to require integration tests.
HAS_RESPONDER_CHANGES := $(shell git diff --name-only origin/main 2>/dev/null | grep -qE 'lib/.*/(responders|nats|consumers)/|lib/.*/bridge.*\.ex|lib/.*/event.*\.ex' && echo 1 || echo 0)

sync-release-version:
	@VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "❌ Failed to resolve version from mix.exs"; exit 1; \
	fi; \
	TIMESTAMP=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	echo "$$VERSION" > .release-published; \
	echo "✅ Synced release version: v$$VERSION ($$TIMESTAMP)"

publish-release:
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL=dispatcher_bot-$$VERSION.tar.gz; \
	echo "Version: $$VERSION"; \
	echo ""; \
	if [ -f "$$TARBALL" ]; then \
		echo "✓ Tarball already exists locally: $$TARBALL (skipping rebuild)"; \
	else \
		echo "📦 Building release (tarball not found locally)..."; \
		if [ "$(HAS_RESPONDER_CHANGES)" = "1" ] && [ "$(SKIP_INTEGRATION_GATE)" != "1" ]; then \
			echo "🔒 Responder/NATS/bridge changes detected. Integration tests required before publish."; \
			$(MAKE) test-integration || { echo "❌ Integration tests failed. Publish blocked."; exit 1; }; \
			echo "✅ Integration tests passed."; \
		else \
			[ "$(HAS_RESPONDER_CHANGES)" = "1" ] && echo "⚠️  Skipping integration gate (SKIP_INTEGRATION_GATE=1)" || true; \
		fi; \
		$(MAKE) release; \
		$(MAKE) test-release-smoke || echo "⚠️  Smoke test warnings (non-blocking) - continuing"; \
		echo "Creating release tarball..."; \
		tar -czf "$$TARBALL" -C _build/prod/rel dispatcher_bot/; \
		echo "✓ Tarball created: $$TARBALL"; \
	fi; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Dispatcher Bot Elixir release v$$VERSION" \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
t$(MAKE) sync-release-version;
	echo ""; \
	echo "Publishing deploy.release.requested to NATS..."; \
	BOT_NAME=$$(basename $$(pwd) | sed 's/bot_army_//'); \
	REPO_SLUG=$$(git config --get remote.origin.url | sed 's/.*\///; s/\.git$$//'); \
	NATS_SERVERS=$${NATS_SERVERS:-nats://localhost:4222}; \
	nats --server "$$NATS_SERVERS" pub deploy.release.requested "$$(jq -n --arg bot "$${BOT_NAME}" --arg repo "$$REPO_SLUG" --arg version "$$VERSION" --arg tag "v$$VERSION" '{bot: $$bot, repo: $$repo, version: $$version, release_tag: $$tag}')" || { echo "⚠️  NATS publish failed (is NATS running?)"; }; \
	echo "✓ Deploy event published (deploy_pipeline_bot will pick it up)"; \
	echo ""

publish-release-force:
	@echo "==============================================="
	@echo "Building OTP release (skipping tests)"
	@echo "==============================================="
	rm -rf _build/prod
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo ""
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL="dispatcher_bot-$$VERSION.tar.gz"; \
	echo "Version: $$VERSION"; \
	echo "Creating release tarball..."; \
	tar -czf "$$TARBALL" -C _build/prod/rel dispatcher_bot/; \
	echo "✓ Tarball created: $$TARBALL"; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Dispatcher Bot Elixir release v$$VERSION. Download and deploy with Jenkins." \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
t$(MAKE) sync-release-version;
	echo ""; \
	echo "Next steps:"; \
	echo "1. Jenkins will automatically detect the new release"; \
	echo "2. Trigger deployment in Jenkins UI or wait for auto-deployment"; \
	echo "3. Check deployment status: make jenkins-logs"

pre-push-cleanup:
	@echo "🧹 Cleaning up pre-push artifacts..."
	@if git diff --quiet git-hooks/pre-push; then \
		echo "✓ No hook changes"; \
	else \
		echo "📋 Staging hook changes..."; \
		git add git-hooks/pre-push; \
		git commit -m "chore: sync pre-push hook" || true; \
	fi
	@if git diff --quiet mix.lock; then \
		echo "✓ No lock file changes"; \
	else \
		echo "📋 Staging lock file changes..."; \
		git add mix.lock; \
		git commit -m "chore: lock file updates from pre-push validation" || true; \
	fi
	@echo "✓ Ready to push"

git-push: pre-push-cleanup
t@BOT_NAME=dispatcher; \
tLOG_FILE="/tmp/git-push-$${BOT_NAME}-$$(date +%s).log"; \
techo "Pushing to origin/main and logging to $$LOG_FILE..."; \
tgit push 2>&1 | tee "$$LOG_FILE"; \
techo "✓ Log saved: $$LOG_FILE"

push-and-publish: git-push publish-release
test-integration-report:
	@echo "=================================================="
	@echo "Running integration tests with reporting"
	@echo "=================================================="
	@REPO_NAME=dispatcher bash $(SCRIPTS_DIRECTORY)/test_integration_report.sh

create-test-failure-tasks:
	@echo "=================================================="
	@echo "Creating GTD tasks for test failures"
	@echo "=================================================="
	@bash $(SCRIPTS_DIRECTORY)/create_test_failure_tasks.sh dispatcher

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

# Smoke test: publish a synthetic alert and verify bridge.agent.dispatch fires
dispatch-test:
	@echo "=== Dispatcher Smoke Test ==="
	@echo "Publishing synthetic alert..."
	@nats pub --server nats://localhost:4223 alerts.test.fire '{"event_id":"smoke-$$RANDOM","source":"test","payload":{"severity":0.5,"message":"smoke test alert"}}'
	@echo "Waiting for dispatch..."
	@sleep 2
	@echo "Smoke test complete. Check dispatcher logs for 'Dispatching to AI' message."
