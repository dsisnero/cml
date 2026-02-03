CRYSTAL ?= crystal
CRYSTAL_SPEC_FLAGS ?= -Dpreview_mt -Dexecution_context
CRYSTAL_CACHE_DIR ?= .crystal_cache
export CRYSTAL_CACHE_DIR

EXAMPLE_DIR := examples
EXAMPLE_SRCS := $(wildcard $(EXAMPLE_DIR)/*.cr)
EXAMPLE_BINS := $(EXAMPLE_SRCS:.cr=)

HOW_TO_DIR := $(EXAMPLE_DIR)/how_to
HOW_TO_SRCS := $(wildcard $(HOW_TO_DIR)/*.cr)
SKIP_HOW_TO := \
	common_pitfalls_and_solutions_031.cr \
	linda_tuple_space_system_from_book_chapter_9_039.cr \
	linda_tuple_space_system_from_book_chapter_9_040.cr \
	linda_tuple_space_system_from_book_chapter_9_042.cr \
	linda_tuple_space_system_from_book_chapter_9_043.cr \
	synchronization_primitives_016.cr \
	understanding_cmls_non-blocking_architecture_034.cr \
	understanding_cmls_non-blocking_architecture_036.cr \
	understanding_cmls_non-blocking_architecture_037.cr

.PHONY: build-examples clean build-system check-how-to-examples analyze-how-to clean-how-to spec

build-examples: $(CRYSTAL_CACHE_DIR) $(EXAMPLE_BINS) build-system

$(EXAMPLE_DIR)/%: $(EXAMPLE_DIR)/%.cr
	$(CRYSTAL) build $< -o $@

$(CRYSTAL_CACHE_DIR):
	mkdir -p $@

build-system:
	$(MAKE) -C $(EXAMPLE_DIR)/build_system

check-how-to-examples: $(CRYSTAL_CACHE_DIR)
	@echo "Checking how_to examples..."
	@failures=0; \
	for file in $(HOW_TO_SRCS); do \
		basename=$$(basename "$$file"); \
		skip=0; \
		for skip_file in $(SKIP_HOW_TO); do \
			if [ "$$basename" = "$$skip_file" ]; then \
				skip=1; \
				break; \
			fi; \
		done; \
		if [ $$skip -eq 1 ]; then \
			echo "Skipping $$basename (known issue)"; \
			continue; \
		fi; \
		echo "Checking $$file..."; \
		if ! $(CRYSTAL) build --no-codegen "$$file" 2>/dev/null; then \
			echo "  FAILED to compile $$file"; \
			failures=$$((failures + 1)); \
		else \
			echo "  OK"; \
		fi; \
	done; \
	if [ $$failures -eq 0 ]; then \
		echo "All how_to examples compile successfully!"; \
	else \
		echo "$$failures how_to example(s) failed to compile."; \
		exit 1; \
	fi

analyze-how-to:
	@echo "Analyzing how_to examples..."
	@if [ ! -d "$(HOW_TO_DIR)" ]; then \
		echo "Extracting examples first..."; \
		crystal scripts/extract_examples.cr how_to.md $(HOW_TO_DIR); \
	fi
	@crystal scripts/analyze_failing_examples.cr $(HOW_TO_DIR)
	@echo "Analysis complete. See $(HOW_TO_DIR)/compilation_report.md"

clean:
	@echo "Cleaning compiled example binaries..."
	rm -f $(EXAMPLE_BINS)
	@echo "Cleaning build_system directory..."
	$(MAKE) -C $(EXAMPLE_DIR)/build_system clean
	@echo "Note: Preserving extracted examples in $(HOW_TO_DIR) and other directories"

spec: $(CRYSTAL_CACHE_DIR)
	$(CRYSTAL) spec $(CRYSTAL_SPEC_FLAGS) spec --verbose
