/*
 * evt_dump — 開我們自己 FsmEventExtractor 對應的 V4L2 capture 裝置,
 * mmap 拿事件 buffer,依 EventProcessor.sv:143 的實際 bit 排列拆出
 * (x, y, type, t) 並印出來。PL 端已經解碼完 EVT2.1,這裡不做任何解碼。
 *
 * 用法: evt_dump /dev/videoN [最多印幾筆,省略則印到 Ctrl+C]
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define NUM_BUFFERS 4

struct mapped_buffer {
	void *start;
	size_t length;
};

static volatile sig_atomic_t g_stop = 0;

static void handle_sigint(int sig)
{
	(void)sig;
	g_stop = 1;
}

static int xioctl(int fd, unsigned long request, void *arg)
{
	int r;
	do {
		r = ioctl(fd, request, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

/* bit 排列來源:EventProcessor.sv:143
 *   m_data_q <= {td_x + x_offset, td_y, td_type[0], time_high_q, td_time};
 * [63:57] 未使用  [56:46] x(11)  [45:35] y(11)  [34] type(1)  [33:0] t(34,微秒)
 */
static void print_event(uint64_t w)
{
	uint32_t t    = (uint32_t)(w & 0x3FFFFFFFFULL);
	uint8_t  type = (uint8_t)((w >> 34) & 0x1);
	uint16_t y    = (uint16_t)((w >> 35) & 0x7FF);
	uint16_t x    = (uint16_t)((w >> 46) & 0x7FF);
	printf("x=%-4u y=%-4u type=%u t=%u\n", x, y, type, t);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "用法: %s /dev/videoN [最多印幾筆,省略則印到 Ctrl+C]\n", argv[0]);
		return 1;
	}
	const char *dev_path = argv[1];
	long max_events = (argc >= 3) ? strtol(argv[2], NULL, 10) : -1;

	int fd = open(dev_path, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		perror("open");
		return 1;
	}

	struct v4l2_capability cap;
	memset(&cap, 0, sizeof(cap));
	if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
		perror("VIDIOC_QUERYCAP");
		close(fd);
		return 1;
	}
	if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) {
		fprintf(stderr, "%s 不是 video capture 裝置\n", dev_path);
		close(fd);
		return 1;
	}
	if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
		fprintf(stderr, "%s 不支援 streaming(mmap)\n", dev_path);
		close(fd);
		return 1;
	}

	struct v4l2_requestbuffers req;
	memset(&req, 0, sizeof(req));
	req.count = NUM_BUFFERS;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
		perror("VIDIOC_REQBUFS");
		close(fd);
		return 1;
	}
	if (req.count < 2) {
		fprintf(stderr, "driver 只給了 %u 個 buffer,太少\n", req.count);
		close(fd);
		return 1;
	}

	struct mapped_buffer buffers[NUM_BUFFERS];
	memset(buffers, 0, sizeof(buffers));

	for (unsigned int i = 0; i < req.count; i++) {
		struct v4l2_buffer buf;
		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;

		if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
			perror("VIDIOC_QUERYBUF");
			close(fd);
			return 1;
		}

		buffers[i].length = buf.length;
		buffers[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
					 MAP_SHARED, fd, buf.m.offset);
		if (buffers[i].start == MAP_FAILED) {
			perror("mmap");
			close(fd);
			return 1;
		}

		if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
			perror("VIDIOC_QBUF");
			close(fd);
			return 1;
		}
	}

	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
		perror("VIDIOC_STREAMON");
		close(fd);
		return 1;
	}

	signal(SIGINT, handle_sigint);

	long printed = 0;
	while (!g_stop && (max_events < 0 || printed < max_events)) {
		fd_set fds;
		FD_ZERO(&fds);
		FD_SET(fd, &fds);
		struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };

		int r = select(fd + 1, &fds, NULL, NULL, &tv);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			perror("select");
			break;
		}
		if (r == 0)
			continue; /* 逾時,還沒新 buffer,回頭檢查 g_stop */

		struct v4l2_buffer buf;
		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		buf.memory = V4L2_MEMORY_MMAP;

		if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
			if (errno == EAGAIN)
				continue;
			perror("VIDIOC_DQBUF");
			break;
		}

		size_t n_events = buf.bytesused / sizeof(uint64_t);
		const uint64_t *words = (const uint64_t *)buffers[buf.index].start;
		for (size_t i = 0; i < n_events && (max_events < 0 || printed < max_events); i++) {
			print_event(words[i]);
			printed++;
		}

		if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
			perror("VIDIOC_QBUF");
			break;
		}
	}

	xioctl(fd, VIDIOC_STREAMOFF, &type);

	for (unsigned int i = 0; i < req.count; i++)
		munmap(buffers[i].start, buffers[i].length);

	close(fd);
	return 0;
}
