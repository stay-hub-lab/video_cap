// SPDX-License-Identifier: GPL-2.0
#pragma once

#include <linux/interrupt.h>
#include <linux/kthread.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/scatterlist.h>
#include <linux/spinlock.h>
#include <linux/timekeeping.h>
#include <linux/types.h>
#include <linux/wait.h>

#include <linux/videodev2.h>

#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/videobuf2-v4l2.h>

struct xdma_dev;

#define DRV_NAME "video_cap_pcie_v4l2"

/*
 * 默认视频参数（当前驱动会把 TRY_FMT/S_FMT 固定到这些默认值，属于 bring-up 取舍）
 * 后续如果要支持动态分辨率/帧率，需要扩展 FPGA 侧以及驱动的寄存器/校验逻辑。
 */
#define VIDEO_WIDTH_DEFAULT  1920
#define VIDEO_HEIGHT_DEFAULT 1080
#define VIDEO_FRAME_RATE_60  60
#define XDMA_USER_IRQ_MAX    16U

/*
 * 自定义 V4L2 controls ID：
 * 一些内核版本对 “PRIVATE_BASE(0x08000000)” 的 class 解析不兼容，会导致 -ERANGE。
 * 这里把自定义控件放到 USER class (V4L2_CID_USER_BASE) 的尾部区域（0xF0..），
 * 既保证 class 合法，又避免与常见的标准 USER controls 冲突。
 */
#define V4L2_CID_VIDEO_CAP_TEST_PATTERN     (V4L2_CID_USER_BASE + 0xF0)
#define V4L2_CID_VIDEO_CAP_SKIP             (V4L2_CID_USER_BASE + 0xF1)
#define V4L2_CID_VIDEO_CAP_VSYNC_TIMEOUT_MS (V4L2_CID_USER_BASE + 0xF2)
#define V4L2_CID_VIDEO_CAP_VSYNC_TIMEOUT    (V4L2_CID_USER_BASE + 0xF3)
#define V4L2_CID_VIDEO_CAP_DMA_ERROR        (V4L2_CID_USER_BASE + 0xF4)

#ifndef V4L2_PIX_FMT_XBGR32
/* v4l2-ctl shows 'XR24' for 32-bit BGRX. */
#define V4L2_PIX_FMT_XBGR32 v4l2_fourcc('X', 'R', '2', '4')
#endif

struct video_cap_stats {
	atomic64_t vsync_isr;
	atomic64_t vsync_wait;
	atomic64_t vsync_timeout;
	atomic64_t dma_submit;
	atomic64_t dma_error;
	atomic64_t dma_short;
	atomic64_t dma_trim;
};

/* vb2 buffer 封装：vb2_v4l2_buffer + 链表节点 */
struct video_cap_buffer {
	struct vb2_v4l2_buffer vb;
	struct list_head list;
};

struct video_cap_multi;

/*
 * 每个 /dev/videoX 的实例（逻辑通道）：
 * - dev->c2h_channel：对应 XDMA 的 C2H engine index
 * - dev->irq_index：对应 XDMA 的 user IRQ bit index（用作 VSYNC）
 *
 * 采集模型：
 * - 用户态 QBUF -> 进入 buf_list
 * - 采集线程等待 VSYNC -> 发起一次整帧 DMA -> vb2_buffer_done()
 */
struct video_cap_dev {
	struct video_cap_multi *multi;
	struct pci_dev *pdev;
	struct xdma_dev *xdev;
	void __iomem *user_regs;
	struct video_cap_stats stats;

	struct video_device vdev;
	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl *ctrl_test_pattern;
	struct v4l2_ctrl *ctrl_skip;
	struct v4l2_ctrl *ctrl_stat_vsync_timeout;
	struct v4l2_ctrl *ctrl_stat_dma_error;
	struct vb2_queue vb_queue;

	struct mutex lock;
	spinlock_t qlock;
	struct list_head buf_list;
	wait_queue_head_t wq;

	wait_queue_head_t vsync_wq;
	atomic64_t vsync_seq;
	u32 vsync_timeout_ms;
	u32 user_irq_mask;

	struct task_struct *thread;
	bool stopping;
	bool streaming;
	unsigned int sequence;

	u32 width;
	u32 height;
	u32 pixfmt;
	u32 bytesperline;
	u32 sizeimage;

	bool test_pattern;
	unsigned int skip;
	unsigned int c2h_channel;
	unsigned int irq_index;

	void *warmup_buf;
	dma_addr_t warmup_dma;
	struct sg_table warmup_sgt;
	struct scatterlist warmup_sg;
	bool warmup_inited;
};

/*
 * 每个 PCIe function 的共享对象：
 * - 一个 PCI function 下可能暴露多个 /dev/videoX（多通道）
 * - user_regs 指向 XDMA user BAR（FPGA 寄存器）
 */
struct video_cap_multi {
	struct pci_dev *pdev;
	struct xdma_dev *xdev;
	void __iomem *user_regs;

	struct v4l2_device v4l2_dev;

	/* register_bank 的 CTRL/TEST_MODE 等为全局控制：当前先限制只允许一路在采集 */
	struct mutex hw_lock;
	struct video_cap_dev *active_stream;

	bool has_per_ch_regs;
	u32 ch_stride;
	u32 ch_count;

	u32 user_irq_mask; /* registered bits */
	unsigned int num_devs;
	struct video_cap_dev **devs;
};

/* ===== 硬件/寄存器 ===== */
/* 读取 FPGA user BAR 寄存器（32-bit） */
u32 video_cap_reg_read32(struct video_cap_dev *dev, u32 off);
/* 写 FPGA user BAR 寄存器（32-bit） */
void video_cap_reg_write32(struct video_cap_dev *dev, u32 off, u32 val);
/* 检测是否支持 per-channel 寄存器窗口（读取 REG_CAPS） */
bool video_cap_detect_per_channel_regs(struct video_cap_multi *m);
/* 计算某通道的寄存器偏移（REG_CH_BASE + ch*stride + off） */
u32 video_cap_ch_reg_off(struct video_cap_dev *dev, u32 ch_off);

/* ===== 统计/打印 ===== */
/* 初始化统计计数器 */
void video_cap_stats_init(struct video_cap_dev *dev);
/* 打印统计计数器（用于 dmesg） */
void video_cap_stats_dump(struct video_cap_dev *dev, const char *tag);

/* ===== FPGA 控制（使能/格式） ===== */
/* 把 dev->pixfmt 同步到 FPGA VID_FORMAT */
void video_cap_apply_hw_format(struct video_cap_dev *dev);
/* 使能/关闭 FPGA 采集（CTRL_ENABLE / CTRL_TEST_MODE） */
int video_cap_enable(struct video_cap_dev *dev, bool enable);

/* ===== vb2 / 采集线程 ===== */
/* VSYNC user IRQ handler（ISR） */
irqreturn_t video_cap_user_irq_handler(int user, void *data);
/* vb2: STREAMOFF 回调（停止采集线程/关闭 IRQ/归还 buffers） */
void video_cap_stop_streaming(struct vb2_queue *vq);
/* vb2 ops 表（queue_setup/buf_queue/start/stop 等） */
extern const struct vb2_ops video_cap_vb2_ops;

/* ===== V4L2 注册/卸载 ===== */
/* 注册一个 /dev/videoX（controls + vb2_queue + video_device） */
int video_cap_register_v4l2(struct video_cap_dev *dev);
/* 注销 /dev/videoX 并释放 controls */
void video_cap_unregister_v4l2(struct video_cap_dev *dev);
/* 判断支持的 V4L2 pixelformat */
bool video_cap_pixfmt_supported(u32 pixfmt);
/* 填充 v4l2_pix_format 的 bytesperline/sizeimage/colorspace 等 */
void video_cap_fill_pix_format(struct v4l2_pix_format *pix, u32 width, u32 height, u32 pixfmt);
