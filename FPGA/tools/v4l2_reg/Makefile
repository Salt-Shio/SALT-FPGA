CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
CFLAGS := -Wall -Wextra -O2

v4l2_reg: v4l2_reg.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f v4l2_reg
