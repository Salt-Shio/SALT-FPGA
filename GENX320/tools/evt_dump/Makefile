CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
CFLAGS := -Wall -Wextra -O2

evt_dump: evt_dump.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f evt_dump
