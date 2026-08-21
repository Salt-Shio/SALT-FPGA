/*
 * v4l2_bias — GenX320 感測器 bias 設定工具:直接對 sensor subdev
 * (/dev/v4l-subdevN)操作 V4L2 control,不依賴 metavision_viewer。
 *
 * bias(bias_fo/bias_hpf/bias_diff_on/bias_diff_off/bias_diff/bias_refr...)
 * 不是標準 V4L2_CID_* 常數,是 genx320 sensor driver 自訂的 control,沒有
 * 固定 CID 可以寫死。作法對照官方 openeb 的 V4L2Controls 機制
 * (hal_psee_plugins/src/boards/v4l2/v4l2_controls.cpp):用
 * VIDIOC_QUERY_EXT_CTRL 迴圈列舉裝置上全部 control,名稱開頭是 "bias_" 的
 * 收進來,之後用名稱字串比對找到對應的 control id,再用
 * VIDIOC_G_EXT_CTRLS / VIDIOC_S_EXT_CTRLS 讀寫。
 *
 * .bias 檔案格式(對照 hal/cpp/src/facilities/i_ll_biases.cpp):每行
 * 「<數值> % <名稱>」,數值可十進位或 0x 開頭十六進位,例如:
 *   51 % bias_diff
 * 空行與開頭是 '%' 的行(header/註解)略過。載入時先驗證全部項目都存在、
 * 都在合法範圍內,一筆有誤就整批中止,不寫入任何一筆。
 *
 * 用法:
 *   v4l2_bias /dev/v4l-subdevN list
 *   v4l2_bias /dev/v4l-subdevN load <path.bias>
 *
 * 依賴:sensor 要先通電(echo on > /sys/class/video4linux/v4l-subdevN/
 * device/power/control),bias 才寫得進去、寫入後才持續生效。這步驟由
 * 使用者自己做,不是這支工具的責任。
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define BIAS_PREFIX "bias_"
#define MAX_BIAS_CTRLS 64

struct bias_ctrl {
	__u32 id;
	char name[32];
	__s64 minimum;
	__s64 maximum;
	__s64 default_value;
};

struct bias_entry {
	char name[32];
	int value;
};

static int xioctl(int fd, unsigned long request, void *arg)
{
	int r;
	do {
		r = ioctl(fd, request, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"用法: %s /dev/v4l-subdevN list\n"
		"      %s /dev/v4l-subdevN load <path.bias>\n",
		prog, prog);
}

/* 列舉裝置上所有名稱開頭是 "bias_" 的 control,寫進 out(最多 max_count
 * 筆),回傳實際筆數;失敗回傳 -1。 */
static int enumerate_bias_controls(int fd, struct bias_ctrl *out, int max_count)
{
	struct v4l2_query_ext_ctrl qec;
	int count = 0;

	memset(&qec, 0, sizeof(qec));
	qec.id = V4L2_CTRL_FLAG_NEXT_CTRL | V4L2_CTRL_FLAG_NEXT_COMPOUND;

	while (xioctl(fd, VIDIOC_QUERY_EXT_CTRL, &qec) == 0) {
		if (!(qec.flags & V4L2_CTRL_FLAG_DISABLED)
		    && qec.type != V4L2_CTRL_TYPE_CTRL_CLASS
		    && strncmp(qec.name, BIAS_PREFIX, strlen(BIAS_PREFIX)) == 0) {
			if (count >= max_count) {
				fprintf(stderr,
					"裝置上 bias control 數量超過上限(%d),提高 MAX_BIAS_CTRLS\n",
					max_count);
				return -1;
			}
			out[count].id = qec.id;
			memcpy(out[count].name, qec.name, sizeof(out[count].name));
			out[count].minimum = qec.minimum;
			out[count].maximum = qec.maximum;
			out[count].default_value = qec.default_value;
			count++;
		}

		qec.id |= V4L2_CTRL_FLAG_NEXT_CTRL | V4L2_CTRL_FLAG_NEXT_COMPOUND;
	}

	if (errno != EINVAL) {
		perror("VIDIOC_QUERY_EXT_CTRL");
		return -1;
	}

	return count;
}

static const struct bias_ctrl *find_bias_ctrl(const struct bias_ctrl *list, int count,
					       const char *name)
{
	int i;

	for (i = 0; i < count; i++) {
		if (strcmp(list[i].name, name) == 0)
			return &list[i];
	}
	return NULL;
}

static int bias_get(int fd, __u32 id, __s32 *value)
{
	struct v4l2_ext_control ctrl;
	struct v4l2_ext_controls ctrls;

	memset(&ctrl, 0, sizeof(ctrl));
	memset(&ctrls, 0, sizeof(ctrls));
	ctrl.id = id;
	ctrls.which = V4L2_CTRL_ID2WHICH(id);
	ctrls.count = 1;
	ctrls.controls = &ctrl;

	if (xioctl(fd, VIDIOC_G_EXT_CTRLS, &ctrls) < 0)
		return -1;

	*value = ctrl.value;
	return 0;
}

static int bias_set(int fd, __u32 id, __s32 value)
{
	struct v4l2_ext_control ctrl;
	struct v4l2_ext_controls ctrls;

	memset(&ctrl, 0, sizeof(ctrl));
	memset(&ctrls, 0, sizeof(ctrls));
	ctrl.id = id;
	ctrl.value = value;
	ctrls.which = V4L2_CTRL_ID2WHICH(id);
	ctrls.count = 1;
	ctrls.controls = &ctrl;

	if (xioctl(fd, VIDIOC_S_EXT_CTRLS, &ctrls) < 0)
		return -1;

	return 0;
}

static int cmd_list(int fd)
{
	struct bias_ctrl ctrls[MAX_BIAS_CTRLS];
	int count = enumerate_bias_controls(fd, ctrls, MAX_BIAS_CTRLS);
	int i;

	if (count < 0)
		return 1;

	if (count == 0) {
		fprintf(stderr, "裝置上找不到任何 bias_* control\n");
		return 1;
	}

	for (i = 0; i < count; i++) {
		__s32 value;

		if (bias_get(fd, ctrls[i].id, &value) < 0) {
			fprintf(stderr, "%-16s 讀取失敗: %s\n", ctrls[i].name, strerror(errno));
			continue;
		}

		printf("%-16s = %-6d [%lld, %lld] (default %lld)\n",
		       ctrls[i].name, value,
		       (long long)ctrls[i].minimum, (long long)ctrls[i].maximum,
		       (long long)ctrls[i].default_value);
	}

	return 0;
}

/* 解析 .bias 檔案,寫進 out(最多 max_count 筆),回傳實際筆數;失敗回傳 -1。 */
static int parse_bias_file(const char *path, struct bias_entry *out, int max_count)
{
	FILE *f = fopen(path, "r");
	char line[256];
	int count = 0;

	if (!f) {
		perror("fopen");
		return -1;
	}

	while (fgets(line, sizeof(line), f)) {
		char value_str[64], sep[8], name[32];
		char *p = line;
		int value, dup, i;

		while (*p == ' ' || *p == '\t')
			p++;

		/* 空行、或開頭是 '%' 的 header/註解行,略過 */
		if (*p == '\0' || *p == '\n' || *p == '%')
			continue;

		if (sscanf(p, "%63s %7s %31s", value_str, sep, name) != 3) {
			fprintf(stderr, "無法解析 bias 檔案這一行: %s", line);
			fclose(f);
			return -1;
		}

		if (strncasecmp(value_str, "0x", 2) == 0)
			value = (int)strtol(value_str, NULL, 16);
		else
			value = (int)strtol(value_str, NULL, 10);

		/* 同名但數值不同:對齊官方 load_from_file 的衝突檢查 */
		dup = -1;
		for (i = 0; i < count; i++) {
			if (strcmp(out[i].name, name) == 0) {
				dup = i;
				break;
			}
		}
		if (dup >= 0) {
			if (out[dup].value != value) {
				fprintf(stderr,
					"bias 檔案對 %s 給了兩個不同數值(%d 與 %d)\n",
					name, out[dup].value, value);
				fclose(f);
				return -1;
			}
			continue;
		}

		if (count >= max_count) {
			fprintf(stderr, "bias 檔案項目數量超過上限(%d)\n", max_count);
			fclose(f);
			return -1;
		}

		strncpy(out[count].name, name, sizeof(out[count].name) - 1);
		out[count].name[sizeof(out[count].name) - 1] = '\0';
		out[count].value = value;
		count++;
	}

	fclose(f);
	return count;
}

static int cmd_load(int fd, const char *path)
{
	struct bias_entry entries[MAX_BIAS_CTRLS];
	struct bias_ctrl ctrls[MAX_BIAS_CTRLS];
	int entry_count = parse_bias_file(path, entries, MAX_BIAS_CTRLS);
	int ctrl_count;
	int i;

	if (entry_count < 0)
		return 1;
	if (entry_count == 0) {
		fprintf(stderr, "bias 檔案沒有任何有效項目: %s\n", path);
		return 1;
	}

	ctrl_count = enumerate_bias_controls(fd, ctrls, MAX_BIAS_CTRLS);
	if (ctrl_count < 0)
		return 1;

	/* 先驗證全部項目都存在且在合法範圍內,一筆有誤就整批中止,不寫入任何一筆 */
	for (i = 0; i < entry_count; i++) {
		const struct bias_ctrl *c = find_bias_ctrl(ctrls, ctrl_count, entries[i].name);

		if (!c) {
			fprintf(stderr, "裝置上找不到 bias control: %s\n", entries[i].name);
			return 1;
		}
		if (entries[i].value < c->minimum || entries[i].value > c->maximum) {
			fprintf(stderr, "%s 數值 %d 超出合法範圍 [%lld, %lld]\n",
				entries[i].name, entries[i].value,
				(long long)c->minimum, (long long)c->maximum);
			return 1;
		}
	}

	for (i = 0; i < entry_count; i++) {
		const struct bias_ctrl *c = find_bias_ctrl(ctrls, ctrl_count, entries[i].name);

		if (bias_set(fd, c->id, entries[i].value) < 0) {
			fprintf(stderr, "%s 寫入失敗: %s\n", entries[i].name, strerror(errno));
			return 1;
		}
		printf("%-16s <- %d\n", entries[i].name, entries[i].value);
	}

	return 0;
}

int main(int argc, char **argv)
{
	const char *dev_path, *cmd;
	int fd, ret;

	if (argc < 3) {
		usage(argv[0]);
		return 1;
	}

	dev_path = argv[1];
	cmd = argv[2];

	fd = open(dev_path, O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}

	if (strcmp(cmd, "list") == 0 && argc == 3) {
		ret = cmd_list(fd);
	} else if (strcmp(cmd, "load") == 0 && argc == 4) {
		ret = cmd_load(fd, argv[3]);
	} else {
		usage(argv[0]);
		ret = 1;
	}

	close(fd);
	return ret;
}
