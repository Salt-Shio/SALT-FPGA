/*
 * evt_dump — PS 端驗證/量測程式:open V4L2 capture 裝置 → mmap → 依
 * EventProcessor.sv:143 的實際 bit 排列拆出 (x, y, type, t)。PL 端已經
 * 解碼完 EVT2.1,這裡不做任何解碼。
 *
 * 兩種輸出模式:
 *   - 預設(不加 -o):逐筆印到 stdout,適合少量資料肉眼看。
 *   - -o <path>:整塊 DMA buffer 直接 write() 成原始二進位(8 bytes/筆,
 *     不逐筆解析),事件率高時也來得及寫。檔案內容跟裝置 mmap 出來的
 *     buffer 逐 byte 相同,本機端用 numpy.fromfile(dtype=np.uint64) 讀回。
 *
 * 不管哪種模式都會定期(約每 1 秒)印一行事件率統計到 stderr,結束時印
 * 總結,用來量測實際場景的事件率。
 *
 * 用法: evt_dump [-n count] [-t seconds] [-o path] /dev/videoN
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
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

static void usage(const char *prog)
{
	fprintf(stderr,
		"用法: %s [-n count] [-t seconds] [-o path] /dev/videoN\n"
		"  -n count    最多處理幾筆事件(省略則不限制)\n"
		"  -t seconds  最多錄幾秒(依處理端時間,省略則不限制)\n"
		"  -o path     存成原始二進位檔(8 bytes/筆);省略則逐筆印到 stdout\n"
		"沒有 -n/-t 時用 Ctrl+C 結束\n",
		prog);
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

static double timespec_diff_sec(struct timespec a, struct timespec b)
{
	return (double)(a.tv_sec - b.tv_sec) + (double)(a.tv_nsec - b.tv_nsec) / 1e9;
}

/* 累積滿 1 秒才印一行,避免高事件率時洗版 stderr */
static void report_rate_if_due(struct timespec *last_report_ts,
				long long *events_since_report,
				long long *bytes_since_report)
{
	struct timespec now_ts;
	double dt;

	clock_gettime(CLOCK_MONOTONIC, &now_ts);
	dt = timespec_diff_sec(now_ts, *last_report_ts);
	if (dt < 1.0)
		return;

	fprintf(stderr, "[rate] %.0f events/s  %.2f MB/s\n",
		(double)*events_since_report / dt,
		(double)*bytes_since_report / dt / (1024.0 * 1024.0));

	*last_report_ts = now_ts;
	*events_since_report = 0;
	*bytes_since_report = 0;
}

int main(int argc, char **argv)
{
	long max_events = -1;
	double max_seconds = -1.0;
	const char *out_path = NULL;
	int opt;

	while ((opt = getopt(argc, argv, "n:t:o:h")) != -1) {
		switch (opt) {
		case 'n':
			max_events = strtol(optarg, NULL, 10);
			break;
		case 't':
			max_seconds = strtod(optarg, NULL);
			break;
		case 'o':
			out_path = optarg;
			break;
		case 'h':
			usage(argv[0]);
			return 0;
		default:
			usage(argv[0]);
			return 1;
		}
	}
	if (optind >= argc) {
		usage(argv[0]);
		return 1;
	}
	const char *dev_path = argv[optind];

	int fd_out = -1;
	if (out_path) {
		fd_out = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd_out < 0) {
			perror("open output");
			return 1;
		}
	}

	int fd = open(dev_path, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		perror("open");
		if (fd_out >= 0)
			close(fd_out);
		return 1;
	}

	struct v4l2_capability cap;
	memset(&cap, 0, sizeof(cap));
	if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
		perror("VIDIOC_QUERYCAP");
		close(fd);
		if (fd_out >= 0)
			close(fd_out);
		return 1;
	}
	if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) {
		fprintf(stderr, "%s 不是 video capture 裝置\n", dev_path);
		close(fd);
		if (fd_out >= 0)
			close(fd_out);
		return 1;
	}
	if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
		fprintf(stderr, "%s 不支援 streaming(mmap)\n", dev_path);
		close(fd);
		if (fd_out >= 0)
			close(fd_out);
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
		if (fd_out >= 0)
			close(fd_out);
		return 1;
	}
	if (req.count < 2) {
		fprintf(stderr, "driver 只給了 %u 個 buffer,太少\n", req.count);
		close(fd);
		if (fd_out >= 0)
			close(fd_out);
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
			if (fd_out >= 0)
				close(fd_out);
			return 1;
		}

		buffers[i].length = buf.length;
		buffers[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
					 MAP_SHARED, fd, buf.m.offset);
		if (buffers[i].start == MAP_FAILED) {
			perror("mmap");
			close(fd);
			if (fd_out >= 0)
				close(fd_out);
			return 1;
		}

		if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
			perror("VIDIOC_QBUF");
			close(fd);
			if (fd_out >= 0)
				close(fd_out);
			return 1;
		}
	}

	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
		perror("VIDIOC_STREAMON");
		close(fd);
		if (fd_out >= 0)
			close(fd_out);
		return 1;
	}

	signal(SIGINT, handle_sigint);

	struct timespec start_ts, last_report_ts, now_ts;
	clock_gettime(CLOCK_MONOTONIC, &start_ts);
	last_report_ts = start_ts;

	long long total_events = 0, total_bytes = 0;
	long long events_since_report = 0, bytes_since_report = 0;

	while (!g_stop) {
		clock_gettime(CLOCK_MONOTONIC, &now_ts);
		if (max_seconds >= 0 && timespec_diff_sec(now_ts, start_ts) >= max_seconds)
			break;
		if (max_events >= 0 && total_events >= max_events)
			break;

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
		if (r == 0) {
			report_rate_if_due(&last_report_ts, &events_since_report, &bytes_since_report);
			continue; /* 逾時,還沒新 buffer,回頭檢查 g_stop/時間上限 */
		}

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
		size_t events_to_take = n_events;
		if (max_events >= 0) {
			long long remaining = max_events - total_events;
			if (remaining < 0)
				remaining = 0;
			if ((long long)events_to_take > remaining)
				events_to_take = (size_t)remaining;
		}
		size_t bytes_to_take = events_to_take * sizeof(uint64_t);

		if (fd_out >= 0) {
			if (bytes_to_take > 0) {
				ssize_t w = write(fd_out, buffers[buf.index].start, bytes_to_take);
				if (w < 0 || (size_t)w != bytes_to_take) {
					perror("write");
					g_stop = 1;
				}
			}
		} else {
			const uint64_t *words = (const uint64_t *)buffers[buf.index].start;
			for (size_t i = 0; i < events_to_take; i++)
				print_event(words[i]);
		}

		total_events += events_to_take;
		total_bytes += bytes_to_take;
		events_since_report += events_to_take;
		bytes_since_report += bytes_to_take;

		if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
			perror("VIDIOC_QBUF");
			break;
		}

		report_rate_if_due(&last_report_ts, &events_since_report, &bytes_since_report);
	}

	clock_gettime(CLOCK_MONOTONIC, &now_ts);
	double total_elapsed = timespec_diff_sec(now_ts, start_ts);
	fprintf(stderr, "[summary] %lld events, %lld bytes, %.3f s elapsed, avg %.0f events/s, avg %.2f MB/s\n",
		total_events, total_bytes, total_elapsed,
		total_elapsed > 0 ? (double)total_events / total_elapsed : 0.0,
		total_elapsed > 0 ? (double)total_bytes / total_elapsed / (1024.0 * 1024.0) : 0.0);

	xioctl(fd, VIDIOC_STREAMOFF, &type);

	for (unsigned int i = 0; i < req.count; i++)
		munmap(buffers[i].start, buffers[i].length);

	close(fd);
	if (fd_out >= 0)
		close(fd_out);
	return 0;
}
