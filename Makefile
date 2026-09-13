NVIM_CURRENT ?= nvim
NVIM_MIN ?= .test-deps/neovim-0.11.7/bin/nvim
PYTHON ?= .test-deps/venv/bin/python
ROOT := $(CURDIR)
DEPS := $(ROOT)/.test-deps
WB16_GRIDS := 160x50,120x35,80x24,60x20

.PHONY: bootstrap test test-integration test-ui test-e2e bench bench-results check-ownership fixtures

bootstrap:
	sh tests/bootstrap.sh

test: bootstrap
	set -eu; for nvim_bin in "$(NVIM_MIN)" "$(NVIM_CURRENT)"; do \
	  echo "== mini.test on $$nvim_bin =="; \
	  WORKBENCH_TEST_DEPS="$(DEPS)" NVIM_TEST_BINARY="$$nvim_bin" \
	    "$$nvim_bin" --clean --headless -u tests/runtime/minimal_init.lua -l tests/runtime/run.lua; \
	done

test-integration: bootstrap
	"$(PYTHON)" -m unittest discover -s tests -p 'test_*.py' -v
	python3 scripts/check_plan.py

test-ui: bootstrap
	set -eu; for nvim_bin in "$(NVIM_MIN)" "$(NVIM_CURRENT)"; do \
	  echo "== RPC UI grids on $$nvim_bin =="; \
	  "$(PYTHON)" tests/e2e/driver.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb06_lifecycle.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb07_files.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb07_stress.py --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb08_navigation.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb20_git.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb21_operations.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb22_replacement.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb23_persistence.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	  "$(PYTHON)" tests/e2e/wb24_theming.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$$nvim_bin"; \
	done

test-e2e: bootstrap
	"$(PYTHON)" tests/e2e/driver.py --self-test --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/driver.py --grid-sizes 80x24 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/driver.py --host --grid-sizes 80x24 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb10_search.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb10_search.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb11_exploration.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb11_exploration.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb13_outline.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb13_outline.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb14_symbols.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb14_symbols.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb15_calls.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb15_calls.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb16_problems.py --grid-sizes "$(WB16_GRIDS)" --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb16_problems.py --grid-sizes "$(WB16_GRIDS)" --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb18_working_set.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb18_working_set.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb19_settings.py --grid-sizes 120x35 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb19_settings.py --grid-sizes 120x35 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb20_git.py --grid-sizes 120x35 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb20_git.py --grid-sizes 120x35 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb21_operations.py --grid-sizes 120x35 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb21_operations.py --grid-sizes 120x35 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb22_replacement.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb22_replacement.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb23_persistence.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb23_persistence.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb24_theming.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb24_theming.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"
	"$(PYTHON)" tests/e2e/wb25_host.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_MIN)"
	"$(PYTHON)" tests/e2e/wb25_host.py --grid-sizes 160x50,120x35,80x24,60x20 --nvim "$(NVIM_CURRENT)"

bench: bootstrap
	"$(PYTHON)" bench/fixtures.py --tier tiny
	"$(PYTHON)" bench/fixtures.py --tier normal
	"$(PYTHON)" bench/fixtures.py --tier stress
	"$(PYTHON)" bench/fixtures.py --tier pathological
	"$(PYTHON)" bench/startup.py --runs 20 --nvim "$(NVIM_CURRENT)"
	$(MAKE) bench-results

bench-results: bootstrap
	set -eu; for nvim_bin in "$(NVIM_MIN)" "$(NVIM_CURRENT)"; do \
	  echo "== results benchmark on $$nvim_bin =="; \
	  "$$nvim_bin" --clean --headless -u NONE -l tests/bench_results.lua; \
	  echo "== Outline benchmark on $$nvim_bin =="; \
	  "$$nvim_bin" --clean --headless -u NONE -l tests/bench_outline.lua; \
	done

fixtures:
	"$(PYTHON)" bench/fixtures.py --tier $(TIER) $(if $(OUTPUT),--output "$(OUTPUT)")

check-ownership:
	python3 tests/check_ownership.py
