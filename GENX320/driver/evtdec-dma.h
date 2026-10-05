/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * SALT-FPGA Event Decoder Video DMA
 *
 * Adapted from Prophesee's psee-dma.c/psee-dma.h (zynq-video-drivers,
 * kernel-5.15 branch, commit 22c8103d047cc7937960fd655d0c6869f745d76b),
 * with the avoid-descriptor-link-corruption.patch fix folded in (the
 * @name field below exists so stop_streaming() can re-request the same
 * DMA channel by name).
 * Copyright (C) Prophesee S.A.
 */

#ifndef EVTDEC_DMA_H
#define EVTDEC_DMA_H

#include <linux/dmaengine.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/videodev2.h>
#include <linux/clk.h>

#include <media/media-entity.h>
#include <media/v4l2-dev.h>
#include <media/v4l2-ctrls.h>
#include <media/videobuf2-v4l2.h>

struct dma_chan;
struct evtdec_composite_device;

/**
 * struct evtdec_pipeline - Xilinx Video IP pipeline structure
 * @pipe: media pipeline
 * @lock: protects the pipeline @stream_count
 * @use_count: number of DMA engines using the pipeline
 * @stream_count: number of DMA engines currently streaming
 * @num_dmas: number of DMA engines in the pipeline
 * @output: DMA engine at the output of the pipeline
 */
struct evtdec_pipeline {
	struct media_pipeline pipe;

	struct mutex lock;
	unsigned int use_count;
	unsigned int stream_count;

	unsigned int num_dmas;
	struct evtdec_dma *output;
};

static inline struct evtdec_pipeline *to_evtdec_pipeline(struct media_entity *e)
{
	return container_of(e->pipe, struct evtdec_pipeline, pipe);
}

/**
 * struct evtdec_dma - Video DMA interface to PS Host
 * @list: list entry in a composite device dmas list
 * @video: V4L2 video device associated with the DMA channel
 * @pad: media pad for the video device entity
 * @evtdec_dev: composite device the DMA channel belongs to
 * @pipe: pipeline belonging to the DMA channel
 * @port: composite device DT node port number for the DMA channel
 * @lock: protects the @queue field
 * @queue: vb2 buffers queue
 * @sequence: V4L2 buffers sequence number
 * @transfer_size: Size of the DMA buffers, =maximum transfer size
 * @queued_bufs: list of queued buffers
 * @queued_lock: protects the buf_queued list
 * @dma: DMA engine channel
 * @name: DMA channel name (e.g. "port0"), kept around so stop_streaming()
 *        can release and re-request the same channel by name
 * @iomem: Mapping of the IP registers in the kernel space
 * @iosize: size of the mapped register bank (in byte)
 * @clk: clock of the video pipeline
 */
struct evtdec_dma {
	struct list_head list;
	struct video_device video;
	struct media_pad pad;

	struct evtdec_composite_device *evtdec_dev;
	struct evtdec_pipeline pipe;
	unsigned int port;

	struct mutex lock;

	struct vb2_queue queue;
	unsigned int sequence;
	u32 transfer_size;

	struct list_head queued_bufs;
	spinlock_t queued_lock;

	void __iomem *iomem;
	resource_size_t iosize;
	struct dma_chan *dma;
	char name[16];
	struct clk *clk;
};

#define to_evtdec_dma(vdev)	container_of(vdev, struct evtdec_dma, video)

int evtdec_dma_init(struct evtdec_composite_device *evtdec_dev, struct evtdec_dma *dma,
		  enum v4l2_buf_type type, unsigned int port, struct resource *io_space);
void evtdec_dma_cleanup(struct evtdec_dma *dma);

#endif /* EVTDEC_DMA_H */
