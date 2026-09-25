# Builds the programs we measure, with the same compiler flags on every
# platform, into build/.
#
#   make             everything
#   make quicksort   one program: quicksort, zstd
#   make clean       remove build/
#
# Third-party programs: a pinned release, its download checked against
# the published SHA-256, optional features off, so every platform builds
# the same code.

CC = gcc
# -g for symbols (instructions are named function+offset; it does not
# change the code); fixed alignment of functions and loops, so code
# layout differs less between builds. No frame pointers: normal builds
# omit them, and perf records no call stacks.
CFLAGS = -O2 -g -falign-functions=32 -falign-loops=32

BUILD = build

ZSTD_VERSION = 1.5.7
ZSTD_SHA256 = eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
ZSTD_URL = https://github.com/facebook/zstd/releases/download/v$(ZSTD_VERSION)/zstd-$(ZSTD_VERSION).tar.gz
ZSTD_SRC = $(BUILD)/zstd-$(ZSTD_VERSION)

all: quicksort zstd

quicksort: $(BUILD)/quicksort
zstd: $(BUILD)/zstd

# every build also depends on this Makefile, so changed flags rebuild it
$(BUILD)/quicksort: src/quicksort.c Makefile | $(BUILD)
	$(CC) $(CFLAGS) -o $@ src/quicksort.c

$(BUILD)/zstd-$(ZSTD_VERSION).tar.gz: | $(BUILD)
	curl -fsSL -o $@.part $(ZSTD_URL)
	echo "$(ZSTD_SHA256)  $@.part" | sha256sum -c --quiet
	mv $@.part $@

# zlib, lzma and lz4 support (other formats) and threads (multithreaded
# and asynchronous I/O) off: zstd's build enables each only if the
# machine has it, and threads would make runs less repeatable
$(BUILD)/zstd: $(BUILD)/zstd-$(ZSTD_VERSION).tar.gz Makefile
	rm -rf $(ZSTD_SRC)
	tar -xzf $< -C $(BUILD)
	$(MAKE) -C $(ZSTD_SRC)/programs zstd CC="$(CC)" CFLAGS="$(CFLAGS)" MOREFLAGS= \
		HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 HAVE_THREAD=0
	cp $(ZSTD_SRC)/programs/zstd $@

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all quicksort zstd clean
