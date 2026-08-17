/*
 * v4l2_reg — 板子上的 v4l2-ctl 沒編進 --get-register/--set-register 功能
 * (v4l2-ctl --help-all 查不到任何 register 相關選項),改直接呼叫
 * driver 本來就實作好的 VIDIOC_DBG_G_REGISTER / VIDIOC_DBG_S_REGISTER
 * (對應 FPGA/driver/evtdec-dma.c 的 g_register()/s_register())。
 *
 * 用法:
 *   v4l2_reg /dev/videoN get <hex位址>
 *   v4l2_reg /dev/videoN set <hex位址> <hex數值>
 *
 * 範例:開 REG_CONFIG.enable_pattern(位址 0x4,bit0):
 *   v4l2_reg /dev/video0 set 0x4 0x1
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/videodev2.h>

int main(int argc, char **argv)
{
	if (argc < 3 || (strcmp(argv[2], "get") == 0 && argc != 4)
		     || (strcmp(argv[2], "set") == 0 && argc != 5)) {
		fprintf(stderr,
			"用法: %s /dev/videoN get <hex位址>\n"
			"      %s /dev/videoN set <hex位址> <hex數值>\n",
			argv[0], argv[0]);
		return 1;
	}

	const char *dev_path = argv[1];
	const char *op = argv[2];
	unsigned long long addr = strtoull(argv[3], NULL, 16);

	int fd = open(dev_path, O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}

	struct v4l2_dbg_register reg;
	memset(&reg, 0, sizeof(reg));
	reg.match.type = V4L2_CHIP_MATCH_BRIDGE;
	reg.match.addr = 0;
	reg.reg = addr;

	if (strcmp(op, "get") == 0) {
		if (ioctl(fd, VIDIOC_DBG_G_REGISTER, &reg) < 0) {
			perror("VIDIOC_DBG_G_REGISTER");
			close(fd);
			return 1;
		}
		printf("0x%llx = 0x%llx\n", addr, (unsigned long long)reg.val);
	} else if (strcmp(op, "set") == 0) {
		reg.val = strtoull(argv[4], NULL, 16);
		if (ioctl(fd, VIDIOC_DBG_S_REGISTER, &reg) < 0) {
			perror("VIDIOC_DBG_S_REGISTER");
			close(fd);
			return 1;
		}
		printf("寫入 0x%llx = 0x%llx 完成\n", addr, (unsigned long long)reg.val);
	} else {
		fprintf(stderr, "第二個參數要是 get 或 set\n");
		close(fd);
		return 1;
	}

	close(fd);
	return 0;
}
