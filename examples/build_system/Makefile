CRYSTAL ?= crystal
CRYSTAL_CACHE_DIR ?= ../../.crystal_cache
CC ?= cc

.PHONY: all build demo clean

all: build

build: build_system

build_system: build_system.cr
	$(CRYSTAL) build $< -o $@

demo: build
	./build_system example.makefile

clean:
	rm -f build_system build_system.dwarf prog *.o
