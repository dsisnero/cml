CRYSTAL ?= crystal
CRYSTAL_CACHE_DIR ?= .crystal_cache
export CRYSTAL_CACHE_DIR

EXAMPLE_DIR := examples
EXAMPLE_SRCS := $(wildcard $(EXAMPLE_DIR)/*.cr)
EXAMPLE_BINS := $(EXAMPLE_SRCS:.cr=)

.PHONY: build-examples clean build-system

build-examples: $(CRYSTAL_CACHE_DIR) $(EXAMPLE_BINS) build-system

$(EXAMPLE_DIR)/%: $(EXAMPLE_DIR)/%.cr
	$(CRYSTAL) build $< -o $@

$(CRYSTAL_CACHE_DIR):
	mkdir -p $@

build-system:
	$(MAKE) -C $(EXAMPLE_DIR)/build_system

clean:
	rm -f $(EXAMPLE_BINS)
	$(MAKE) -C $(EXAMPLE_DIR)/build_system clean
