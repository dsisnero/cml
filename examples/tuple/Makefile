CRYSTAL ?= crystal
CRYSTAL_CACHE_DIR ?= ../../.crystal-cache

.PHONY: dining-demo dining-sml dining-distributed md5-cache-demo md5-cache-serial md5-cache-parallel md5-cache-hyperfine

dining-demo:
	@mkdir -p $(CRYSTAL_CACHE_DIR)
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) run dining_philosophers.cr -- --servers $${SERVERS:-2} --philosophers $${PHILOSOPHERS:-5} --rounds $${ROUNDS:-3}

md5-cache-demo:
	@set -e; \
	COMPARE_FLAG="--compare"; \
	if [ "$${COMPARE:-1}" = "0" ]; then COMPARE_FLAG="--no-compare"; fi; \
	mkdir -p $(CRYSTAL_CACHE_DIR); \
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) run directory_md5_cache.cr -- --dir $${DIR:-../..} --workers $${WORKERS:-4} --repeats $${REPEATS:-2} --iterations $${ITERATIONS:-100} $$COMPARE_FLAG $${VERBOSE:+--verbose}

md5-cache-serial:
	@mkdir -p $(CRYSTAL_CACHE_DIR)
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) run directory_md5_cache.cr -- --dir $${DIR:-../..} --workers 1 --repeats $${REPEATS:-2} --iterations $${ITERATIONS:-100} --no-compare $${VERBOSE:+--verbose}

md5-cache-parallel:
	@mkdir -p $(CRYSTAL_CACHE_DIR)
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) run directory_md5_cache.cr -- --dir $${DIR:-../..} --workers $${WORKERS:-4} --repeats $${REPEATS:-2} --iterations $${ITERATIONS:-100} --no-compare $${VERBOSE:+--verbose}

md5-cache-hyperfine:
	@set -e; \
	mkdir -p $(CRYSTAL_CACHE_DIR); \
	command -v hyperfine >/dev/null 2>&1 || { echo "hyperfine is required (brew install hyperfine)"; exit 1; }; \
	BIN="$(CRYSTAL_CACHE_DIR)/directory_md5_cache_bench"; \
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) build directory_md5_cache.cr -o $$BIN; \
	PAR_WORKERS=$${WORKERS:-4}; \
	DIR_PATH=$${DIR:-../..}; \
	REP=$${REPEATS:-2}; \
	ITER=$${ITERATIONS:-100}; \
	WARM=$${WARMUP:-1}; \
	RUNS=$${RUNS:-5}; \
	hyperfine --warmup $$WARM --runs $$RUNS \
	  "$$BIN --dir $$DIR_PATH --workers 1 --repeats $$REP --iterations $$ITER --no-compare" \
	  "$$BIN --dir $$DIR_PATH --workers $$PAR_WORKERS --repeats $$REP --iterations $$ITER --no-compare"

dining-sml:
	PHILOSOPHERS=$${PHILOSOPHERS:-5} ROUNDS=$${ROUNDS:-3} sml < dining_philosophers.sml

dining-distributed:
	@set -e; \
	NODES=$${NODES:-3}; \
	ROUNDS=$${ROUNDS:-2}; \
	PORT0=$${PORT0:-7100}; \
	PORT1=$${PORT1:-7101}; \
	PORT2=$${PORT2:-7102}; \
	LINGER=$${LINGER:-1.0}; \
	VERBOSE_FLAG=""; \
	if [ "$${VERBOSE:-0}" = "1" ]; then VERBOSE_FLAG="--verbose"; fi; \
	mkdir -p $(CRYSTAL_CACHE_DIR); \
	rm -f node0.log node1.log node2.log; \
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) run dining_philosophers_distributed.cr -- --local-port $$PORT0 --remote-hosts "" --philosophers $$NODES --rounds $$ROUNDS --linger $$LINGER $$VERBOSE_FLAG > node0.log 2>&1 & p0=$$!; \
	sleep 0.6; \
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) run dining_philosophers_distributed.cr -- --local-port $$PORT1 --remote-hosts "127.0.0.1:$$PORT0" --philosophers $$NODES --rounds $$ROUNDS --linger $$LINGER $$VERBOSE_FLAG > node1.log 2>&1 & p1=$$!; \
	sleep 0.6; \
	CRYSTAL_CACHE_DIR=$(CRYSTAL_CACHE_DIR) $(CRYSTAL) run dining_philosophers_distributed.cr -- --local-port $$PORT2 --remote-hosts "127.0.0.1:$$PORT0,127.0.0.1:$$PORT1" --philosophers $$NODES --rounds $$ROUNDS --linger $$LINGER $$VERBOSE_FLAG > node2.log 2>&1 & p2=$$!; \
	wait $$p0 $$p1 $$p2; \
	echo "---- node0.log ----"; cat node0.log; \
	echo "---- node1.log ----"; cat node1.log; \
	echo "---- node2.log ----"; cat node2.log
