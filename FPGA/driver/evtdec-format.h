/* SPDX-License-Identifier: GPL-2.0-only */

#include <linux/videodev2.h>

/* Our output is a raw (x,y,type,t) event stream decoded on the PL side
 * (FPGA/EvtDecoder), not any of the EVTx formats the official Prophesee
 * driver stack uses — so unlike psee-format.h (which this file replaces),
 * there is no MEDIA_BUS_FMT_* counterpart: nothing upstream ever produces
 * this format, our module is the one that creates it.
 *
 * Value chosen in the vendor-specific fourcc range, far enough from
 * existing formats to avoid collisions.
 */
#ifndef V4L2_PIX_FMT_CSNN_XYT
#define V4L2_PIX_FMT_CSNN_XYT v4l2_fourcc('C', 'S', 'X', 'T')
#endif
