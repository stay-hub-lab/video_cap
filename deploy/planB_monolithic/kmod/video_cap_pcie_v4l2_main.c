// SPDX-License-Identifier: GPL-2.0
/*
 * PlanB 单模块 PCIe 视频采集驱动。
 *
 * 本模块做什么：
 * - 将 Xilinx XDMA 的核心源码直接编译进同一个 .ko（单模块集成）
 *   不再依赖系统里单独加载的 xdma.ko。
 * - 通过 V4L2 暴露一个未压缩的视频采集设备：/dev/videoX
 *
 * 数据通路（每帧）：
 *   VSYNC（user IRQ）-> 唤醒采集线程 -> XDMA C2H DMA 写入 vb2 buffer
 *   -> vb2_buffer_done() -> 用户态 mmap/read 取帧
 *
 * 说明：
 * - 需要 FPGA bitstream 把 VSYNC/帧边界信号连接到 XDMA 的某一路 user IRQ。
 * - 目前像素格式固定为 XBGR32（fourcc 'XR24'）；后续可扩展更多格式。
 */

#include <linux/delay.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/kthread.h>
#include <linux/list.h>
#include <linux/limits.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/timekeeping.h>

#include <linux/videodev2.h>

#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/videobuf2-dma-sg.h>
#include <media/videobuf2-v4l2.h>

/* XDMA 核心源码（已复制到 deploy/planB_monolithic/kmod/xdma，随本方案一起编译进 .ko）。 */
#include "libxdma.h"
#include "libxdma_api.h"

#include "video_cap_regs.h"

#define DRV_NAME "video_cap_pcie_v4l2"

#define VIDEO_WIDTH_DEFAULT  1920
#define VIDEO_HEIGHT_DEFAULT 1080
#define VIDEO_FRAME_RATE_60  60
#define XDMA_USER_IRQ_MAX    16U

static bool video_cap_pixfmt_supported(u32 pixfmt)
{
	switch (pixfmt) {
	case V4L2_PIX_FMT_XBGR32: /* ffplay/v4l2-ctl 显示为 fourcc 'XR24'，对应像素格式 bgr0 */
	case V4L2_PIX_FMT_YUYV:   /* fourcc 'YUYV'，对应像素格式 yuyv422 */
		return true;
	default:
		return false;
	}
}

static u32 video_cap_pixfmt_to_fpga_vid_fmt(u32 pixfmt)
{
	switch (pixfmt) {
	case V4L2_PIX_FMT_YUYV:
		return VID_FMT_YUV422;
	case V4L2_PIX_FMT_XBGR32:
	default:
		return VID_FMT_RGB888;
	}
}

static void video_cap_fill_pix_format(struct v4l2_pix_format *pix, u32 width, u32 height, u32 pixfmt)
{
	pix->width = width;
	pix->height = height;
	pix->pixelformat = pixfmt;
	pix->field = V4L2_FIELD_NONE;

	if (pixfmt == V4L2_PIX_FMT_YUYV) {
		pix->bytesperline = width * 2;
		pix->sizeimage = width * height * 2;
		pix->colorspace = V4L2_COLORSPACE_REC709;
	} else {
		pix->bytesperline = width * 4;
		pix->sizeimage = width * height * 4;
		pix->colorspace = V4L2_COLORSPACE_SRGB;
	}
}

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

/* 单个缓冲区的管理信息（vb2 负责实际内存页的分配与映射）。 */
struct video_cap_buffer {
	struct vb2_v4l2_buffer vb;
	struct list_head list;
};

/*
 * 每个被本驱动绑定的 PCIe function 对应一个设备实例。
 * - PCI/XDMA 状态：xdev + BAR 映射地址
 * - V4L2/vb2 状态：v4l2_dev/vdev/vb_queue
 * - 采集工作：独立 kthread（逻辑简单、时序确定）
 */
struct video_cap_dev {
	struct pci_dev *pdev;
	struct xdma_dev *xdev;
	void __iomem *user_regs;
	struct video_cap_stats stats;

	struct v4l2_device v4l2_dev;
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

/* 模块参数：方便 bring-up；后续可迁移到 V4L2 controls（运行时可调，不必重载模块）。 */
static unsigned int c2h_channel;
module_param(c2h_channel, uint, 0644);
MODULE_PARM_DESC(c2h_channel, "XDMA C2H channel index (default 0)");

static unsigned int irq_index = 1;
module_param(irq_index, uint, 0644);
MODULE_PARM_DESC(irq_index, "XDMA user IRQ index used as VSYNC (default 1)");

static bool test_pattern = true;
module_param(test_pattern, bool, 0644);
MODULE_PARM_DESC(test_pattern, "Enable test pattern (color bar) in FPGA");

static unsigned int skip;
module_param(skip, uint, 0644);
MODULE_PARM_DESC(skip, "Discard N frames after enable (warm-up)");

static unsigned int vsync_timeout_ms = 1000;
module_param(vsync_timeout_ms, uint, 0644);
MODULE_PARM_DESC(vsync_timeout_ms, "VSYNC wait timeout in ms (default 1000)");

static void video_cap_stats_init(struct video_cap_dev *dev)
{
	atomic64_set(&dev->stats.vsync_isr, 0);
	atomic64_set(&dev->stats.vsync_wait, 0);
	atomic64_set(&dev->stats.vsync_timeout, 0);
	atomic64_set(&dev->stats.dma_submit, 0);
	atomic64_set(&dev->stats.dma_error, 0);
	atomic64_set(&dev->stats.dma_short, 0);
	atomic64_set(&dev->stats.dma_trim, 0);
}

static void video_cap_stats_dump(struct video_cap_dev *dev, const char *tag)
{
	dev_info(&dev->pdev->dev,
		 "%s: vsync_isr=%lld vsync_wait=%lld vsync_timeout=%lld dma_submit=%lld dma_error=%lld dma_short=%lld dma_trim=%lld\n",
		 tag,
		 (long long)atomic64_read(&dev->stats.vsync_isr),
		 (long long)atomic64_read(&dev->stats.vsync_wait),
		 (long long)atomic64_read(&dev->stats.vsync_timeout),
		 (long long)atomic64_read(&dev->stats.dma_submit),
		 (long long)atomic64_read(&dev->stats.dma_error),
		 (long long)atomic64_read(&dev->stats.dma_short),
		 (long long)atomic64_read(&dev->stats.dma_trim));
}

static int video_cap_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct video_cap_dev *dev =
		container_of(ctrl->handler, struct video_cap_dev, ctrl_handler);

	/*
	 * 为了简化状态机：streaming 期间禁止修改这些参数。
	 * 如果后续确实需要“热切换测试图”，可以在这里加寄存器更新逻辑。
	 */
	if (dev->streaming)
		return -EBUSY;

	switch (ctrl->id) {
	case V4L2_CID_VIDEO_CAP_TEST_PATTERN:
		dev->test_pattern = !!ctrl->val;
		return 0;
	case V4L2_CID_VIDEO_CAP_SKIP:
		dev->skip = (unsigned int)ctrl->val;
		return 0;
	case V4L2_CID_VIDEO_CAP_VSYNC_TIMEOUT_MS:
		dev->vsync_timeout_ms = (u32)ctrl->val;
		return 0;
	default:
		return -EINVAL;
	}
}

static int video_cap_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
	struct video_cap_dev *dev =
		container_of(ctrl->handler, struct video_cap_dev, ctrl_handler);
	s64 value;

	switch (ctrl->id) {
	case V4L2_CID_VIDEO_CAP_VSYNC_TIMEOUT:
		value = atomic64_read(&dev->stats.vsync_timeout);
		ctrl->val = (value > INT_MAX) ? INT_MAX : (int)value;
		return 0;
	case V4L2_CID_VIDEO_CAP_DMA_ERROR:
		value = atomic64_read(&dev->stats.dma_error);
		ctrl->val = (value > INT_MAX) ? INT_MAX : (int)value;
		return 0;
	default:
		return -EINVAL;
	}
}

static const struct v4l2_ctrl_ops video_cap_ctrl_ops = {
	.s_ctrl = video_cap_s_ctrl,
	.g_volatile_ctrl = video_cap_g_volatile_ctrl,
};

static struct v4l2_ctrl *video_cap_new_ctrl(struct video_cap_dev *dev,
					    const struct v4l2_ctrl_config *cfg)
{
	struct v4l2_ctrl *ctrl;

	ctrl = v4l2_ctrl_new_custom(&dev->ctrl_handler, cfg, NULL);
	if (dev->ctrl_handler.error)
		dev_err(&dev->pdev->dev, "create ctrl '%s'(0x%x) failed: %d\n",
			cfg->name ? cfg->name : "?", cfg->id, dev->ctrl_handler.error);
	return ctrl;
}

static int video_cap_init_controls(struct video_cap_dev *dev)
{
	struct v4l2_ctrl_config cfg;
	int ret;

	v4l2_ctrl_handler_init(&dev->ctrl_handler, 8);

	memset(&cfg, 0, sizeof(cfg));
	cfg.ops = &video_cap_ctrl_ops;
	cfg.id = V4L2_CID_VIDEO_CAP_TEST_PATTERN;
	cfg.name = "video_cap_test_pattern";
	cfg.type = V4L2_CTRL_TYPE_BOOLEAN;
	cfg.min = 0;
	cfg.max = 1;
	cfg.step = 1;
	cfg.def = dev->test_pattern ? 1 : 0;
	dev->ctrl_test_pattern = video_cap_new_ctrl(dev, &cfg);

	memset(&cfg, 0, sizeof(cfg));
	cfg.ops = &video_cap_ctrl_ops;
	cfg.id = V4L2_CID_VIDEO_CAP_SKIP;
	cfg.name = "video_cap_skip";
	cfg.type = V4L2_CTRL_TYPE_INTEGER;
	cfg.min = 0;
	cfg.max = 60;
	cfg.step = 1;
	cfg.def = dev->skip;
	dev->ctrl_skip = video_cap_new_ctrl(dev, &cfg);

	/* VSYNC 等待超时：调试/现场环境可按需调小（低延时场景建议 30~200ms）。 */
	memset(&cfg, 0, sizeof(cfg));
	cfg.ops = &video_cap_ctrl_ops;
	cfg.id = V4L2_CID_VIDEO_CAP_VSYNC_TIMEOUT_MS;
	cfg.name = "video_cap_vsync_timeout_ms";
	cfg.type = V4L2_CTRL_TYPE_INTEGER;
	cfg.min = 1;
	cfg.max = 5000;
	cfg.step = 1;
	cfg.def = dev->vsync_timeout_ms;
	video_cap_new_ctrl(dev, &cfg);

	/*
	 * 运行统计：只读 + volatile（每次 GET_CTRL 都会刷新）。
	 * 内核 V4L2 ctrl 的赋值接口在不同版本上有差异；这里用 32-bit counter
	 * 以保证兼容性（达到上限后钳位到 INT_MAX）。
	 */
	memset(&cfg, 0, sizeof(cfg));
	cfg.ops = &video_cap_ctrl_ops;
	cfg.id = V4L2_CID_VIDEO_CAP_VSYNC_TIMEOUT;
	cfg.name = "video_cap_vsync_timeout";
	cfg.type = V4L2_CTRL_TYPE_INTEGER;
	cfg.min = 0;
	cfg.max = INT_MAX;
	cfg.step = 1;
	cfg.def = 0;
	cfg.flags = V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE;
	dev->ctrl_stat_vsync_timeout = video_cap_new_ctrl(dev, &cfg);
	if (dev->ctrl_stat_vsync_timeout)
		dev->ctrl_stat_vsync_timeout->flags |= V4L2_CTRL_FLAG_READ_ONLY |
						       V4L2_CTRL_FLAG_VOLATILE;

	memset(&cfg, 0, sizeof(cfg));
	cfg.ops = &video_cap_ctrl_ops;
	cfg.id = V4L2_CID_VIDEO_CAP_DMA_ERROR;
	cfg.name = "video_cap_dma_error";
	cfg.type = V4L2_CTRL_TYPE_INTEGER;
	cfg.min = 0;
	cfg.max = INT_MAX;
	cfg.step = 1;
	cfg.def = 0;
	cfg.flags = V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE;
	dev->ctrl_stat_dma_error = video_cap_new_ctrl(dev, &cfg);
	if (dev->ctrl_stat_dma_error)
		dev->ctrl_stat_dma_error->flags |= V4L2_CTRL_FLAG_READ_ONLY |
						   V4L2_CTRL_FLAG_VOLATILE;

	ret = dev->ctrl_handler.error;
	if (ret) {
		v4l2_ctrl_handler_free(&dev->ctrl_handler);
		dev->ctrl_handler.error = 0;
		return ret;
	}

	dev->v4l2_dev.ctrl_handler = &dev->ctrl_handler;
	dev->vdev.ctrl_handler = &dev->ctrl_handler;
	return 0;
}

static void video_cap_free_controls(struct video_cap_dev *dev)
{
	v4l2_ctrl_handler_free(&dev->ctrl_handler);
	dev->v4l2_dev.ctrl_handler = NULL;
	dev->vdev.ctrl_handler = NULL;
}

/* FPGA 用户寄存器写辅助函数（user_regs 指向 XDMA user BAR 的映射）。 */
static void video_cap_reg_write32(struct video_cap_dev *dev, u32 off, u32 val)
{
	iowrite32(val, (u8 __iomem *)dev->user_regs + off);
}

static void video_cap_apply_hw_format(struct video_cap_dev *dev)
{
	u32 fmt;

	if (!dev->user_regs)
		return;

	fmt = video_cap_pixfmt_to_fpga_vid_fmt(dev->pixfmt);
	video_cap_reg_write32(dev, REG_VID_FORMAT, fmt);
}

/* 使能/关闭 FPGA 采集（可选打开测试图）。 */
static int video_cap_enable(struct video_cap_dev *dev, bool enable)
{
	u32 ctrl = 0;

	if (!dev->user_regs)
		return -ENODEV;

	if (enable) {
		/* enable 前把像素打包格式同步给 FPGA（避免用户空间未显式 S_FMT 的情况） */
		video_cap_apply_hw_format(dev);
		ctrl |= CTRL_ENABLE;
		if (dev->test_pattern)
			ctrl |= CTRL_TEST_MODE;
	}

	video_cap_reg_write32(dev, REG_CONTROL, ctrl);
	return 0;
}

/*
 * VSYNC 中断处理函数（XDMA 的 user IRQ）。
 * 尽量保持 ISR 最小化：只记录“来了一个 VSYNC”，并唤醒采集线程。
 */
static irqreturn_t video_cap_user_irq_handler(int user, void *data)
{
	struct video_cap_dev *dev = data;

	(void)user;

	atomic64_inc(&dev->stats.vsync_isr);
	atomic64_inc(&dev->vsync_seq);
	wake_up_interruptible(&dev->vsync_wq);
	return IRQ_HANDLED;
}

/*
 * 等待 VSYNC 到来（或 stop/timeout）。
 * 使用“递增序号”而不是“pending 计数”：
 * - 不会因为 ISR/线程调度造成 pending 计数积压或丢失
 * - 每次只需关心“是否出现了新的 VSYNC”
 */
static int video_cap_wait_vsync(struct video_cap_dev *dev, u64 *last_seq)
{
	long rv;
	u64 seq_before;
	unsigned long timeout;

	atomic64_inc(&dev->stats.vsync_wait);
	seq_before = *last_seq;
	timeout = msecs_to_jiffies(dev->vsync_timeout_ms);
	rv = wait_event_interruptible_timeout(
		dev->vsync_wq,
		dev->stopping || (u64)atomic64_read(&dev->vsync_seq) != seq_before, timeout);
	if (rv < 0)
		return (int)rv;
	if (rv == 0) {
		atomic64_inc(&dev->stats.vsync_timeout);
		return -ETIMEDOUT;
	}
	if (dev->stopping)
		return -EINTR;

	*last_seq = (u64)atomic64_read(&dev->vsync_seq);
	return 0;
}

/*
 * 把“一帧数据”通过 XDMA C2H DMA 写入 vb2 buffer。
 * vb2-dma-sg 返回的 sg_table 已经针对 &pdev->dev 做过 DMA map。
 */
static int video_cap_dma_read_frame(struct video_cap_dev *dev, struct vb2_buffer *vb)
{
	struct sg_table *sgt;
	struct scatterlist *sg, *last_sg = NULL;
	ssize_t n;
	u32 orig_nents;
	u32 used_nents;
	u32 last_orig_len = 0;
	u32 last_orig_dma_len = 0;
	size_t remaining;
	bool trim_applied = false;

	sgt = vb2_dma_sg_plane_desc(vb, 0);
	if (!sgt)
		return -EFAULT;

	/*
	 * vb2-dma-sg 提供的 sg_table 已经对 vb2_queue.dev 做过 DMA map
	 *（这里我们设置为 &pdev->dev），所以 dma_mapped=true。
	 */
	atomic64_inc(&dev->stats.dma_submit);
	/*
	 * vb2-dma-sg buffers are often page-aligned, so the sg_table total DMA
	 * length can be larger than dev->sizeimage. The FPGA only produces
	 * sizeimage bytes per frame, so cap the DMA transfer length to exactly
	 * dev->sizeimage to avoid timeouts/short frames.
	 */
	orig_nents = sgt->nents;
	remaining = dev->sizeimage;
	sg = sgt->sgl;
	for (used_nents = 0; used_nents < orig_nents && sg; used_nents++, sg = sg_next(sg)) {
		u32 seg_len = sg_dma_len(sg);

		if (seg_len >= remaining) {
			if (seg_len != remaining || (used_nents + 1) < orig_nents)
				trim_applied = true;
			last_sg = sg;
			last_orig_len = sg->length;
			last_orig_dma_len = sg_dma_len(sg);
			sg->length = (u32)remaining;
			sg_dma_len(sg) = (u32)remaining;
			remaining = 0;
			used_nents++; /* include last_sg */
			break;
		}
		remaining -= seg_len;
	}
	if (remaining != 0)
		return -EFAULT;
	sgt->nents = used_nents;
	if (trim_applied)
		atomic64_inc(&dev->stats.dma_trim);

	n = xdma_xfer_submit(dev->xdev, dev->c2h_channel, false, 0, sgt, true, 1000);

	/* Restore sg_table for vb2 reuse */
	sgt->nents = orig_nents;
	if (last_sg) {
		last_sg->length = last_orig_len;
		sg_dma_len(last_sg) = last_orig_dma_len;
	}

	if (n < 0) {
		atomic64_inc(&dev->stats.dma_error);
		return (int)n;
	}
	if (n != dev->sizeimage) {
		atomic64_inc(&dev->stats.dma_short);
		return -EIO;
	}
	return 0;
}

/*
 * Warm-up（可选）：
 * 使能采集后先读并丢弃 N 帧，用于对齐流水线/稳定输出。
 * 这里分配一块 coherent 的临时缓冲区，并封装成单 entry 的 sg_table。
 */
static int video_cap_warmup_init(struct video_cap_dev *dev)
{
	if (!dev->skip || dev->warmup_inited)
		return 0;

	dev->warmup_buf = dma_alloc_coherent(&dev->pdev->dev, dev->sizeimage,
					     &dev->warmup_dma, GFP_KERNEL);
	if (!dev->warmup_buf)
		return -ENOMEM;

	sg_init_table(&dev->warmup_sg, 1);
	sg_set_page(&dev->warmup_sg, virt_to_page(dev->warmup_buf), dev->sizeimage,
		    offset_in_page(dev->warmup_buf));
	sg_dma_address(&dev->warmup_sg) = dev->warmup_dma;
	sg_dma_len(&dev->warmup_sg) = dev->sizeimage;
	dev->warmup_sgt.sgl = &dev->warmup_sg;
	dev->warmup_sgt.orig_nents = 1;
	dev->warmup_sgt.nents = 1;
	dev->warmup_inited = true;
	return 0;
}

/* 释放 warm-up 资源。 */
static void video_cap_warmup_free(struct video_cap_dev *dev)
{
	if (dev->warmup_buf) {
		dma_free_coherent(&dev->pdev->dev, dev->sizeimage, dev->warmup_buf,
				  dev->warmup_dma);
		dev->warmup_buf = NULL;
	}
	dev->warmup_inited = false;
}

/* 从队列取出下一个待填充的 vb2 buffer（采集线程调用）。 */
static struct video_cap_buffer *video_cap_next_buf(struct video_cap_dev *dev)
{
	struct video_cap_buffer *buf = NULL;
	unsigned long flags;

	spin_lock_irqsave(&dev->qlock, flags);
	if (!list_empty(&dev->buf_list)) {
		buf = list_first_entry(&dev->buf_list, struct video_cap_buffer, list);
		list_del(&buf->list);
	}
	spin_unlock_irqrestore(&dev->qlock, flags);

	return buf;
}

/* 将当前所有已排队但未完成的 buffer 以指定状态返回给 vb2。 */
static void video_cap_return_all_buffers(struct video_cap_dev *dev, enum vb2_buffer_state state)
{
	LIST_HEAD(list);
	unsigned long flags;

	spin_lock_irqsave(&dev->qlock, flags);
	list_splice_init(&dev->buf_list, &list);
	spin_unlock_irqrestore(&dev->qlock, flags);

	while (!list_empty(&list)) {
		struct video_cap_buffer *buf =
			list_first_entry(&list, struct video_cap_buffer, list);

		list_del(&buf->list);
		vb2_buffer_done(&buf->vb.vb2_buf, state);
	}
}

/*
 * 采集线程：
 * - 等待用户态 QBUF 把 buffer 入队
 * - 等待 VSYNC
 * - DMA 一帧数据写入该 buffer
 */
static int video_cap_thread_fn(void *data)
{
	struct video_cap_dev *dev = data;
	u64 vsync_seq = (u64)atomic64_read(&dev->vsync_seq);

	while (!kthread_should_stop()) {
		struct video_cap_buffer *buf;
		int ret;

		wait_event_interruptible(dev->wq,
					 dev->stopping || !list_empty(&dev->buf_list) ||
						 kthread_should_stop());
		if (dev->stopping || kthread_should_stop())
			break;

		buf = video_cap_next_buf(dev);
		if (!buf)
			continue;

		ret = video_cap_wait_vsync(dev, &vsync_seq);
		if (ret)
			goto buf_err;

		ret = video_cap_dma_read_frame(dev, &buf->vb.vb2_buf);
		if (ret)
			goto buf_err;

		buf->vb.sequence = dev->sequence++;
		buf->vb.field = V4L2_FIELD_NONE;
		buf->vb.vb2_buf.timestamp = ktime_get_ns();
		vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_DONE);
		continue;

buf_err:
		vb2_buffer_done(&buf->vb.vb2_buf, VB2_BUF_STATE_ERROR);
		if (ret && ret != -ERESTARTSYS) {
			if (ret == -ETIMEDOUT)
				dev_err_ratelimited(&dev->pdev->dev, "vsync timeout\n");
			else
				dev_err_ratelimited(&dev->pdev->dev, "capture error: %d\n", ret);
		}
	}

	return 0;
}

/* vb2：设置 buffer plane 数与大小（单 plane，大小为 sizeimage）。 */
static int video_cap_queue_setup(struct vb2_queue *vq, unsigned int *nbuffers,
				 unsigned int *nplanes, unsigned int sizes[],
				 struct device *alloc_devs[])
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vq);

	*nplanes = 1;
	sizes[0] = dev->sizeimage;

	if (*nbuffers < 4)
		*nbuffers = 4;

	return 0;
}

/* vb2：校验 buffer 足够大，并设置 payload size。 */
static int video_cap_buf_prepare(struct vb2_buffer *vb)
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vb->vb2_queue);

	if (vb2_plane_size(vb, 0) < dev->sizeimage)
		return -EINVAL;

	vb2_set_plane_payload(vb, 0, dev->sizeimage);
	return 0;
}

/* vb2：用户态把 buffer 入队后，加入待处理链表，唤醒采集线程。 */
static void video_cap_buf_queue(struct vb2_buffer *vb)
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vb->vb2_queue);
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
	struct video_cap_buffer *buf = container_of(vbuf, struct video_cap_buffer, vb);
	unsigned long flags;

	spin_lock_irqsave(&dev->qlock, flags);
	list_add_tail(&buf->list, &dev->buf_list);
	spin_unlock_irqrestore(&dev->qlock, flags);

	wake_up(&dev->wq);
}

/*
 * vb2：STREAMON 入口。
 * 使能 user IRQ 与 FPGA 采集，可选 warm-up，然后启动采集线程。
 */
static int video_cap_start_streaming(struct vb2_queue *vq, unsigned int count)
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vq);
	unsigned int i;
	int ret;
	u64 vsync_seq;

	(void)count;

	dev->stopping = false;
	dev->sequence = 0;
	atomic64_set(&dev->vsync_seq, 0);
	vsync_seq = 0;

	ret = xdma_user_isr_enable(dev->xdev, dev->user_irq_mask);
	if (ret) {
		dev_err(&dev->pdev->dev, "enable user irq failed: %d\n", ret);
		video_cap_return_all_buffers(dev, VB2_BUF_STATE_QUEUED);
		return ret;
	}

	ret = video_cap_enable(dev, true);
	if (ret)
		goto err_irq;

	ret = video_cap_warmup_init(dev);
	if (ret)
		goto err_disable;

	for (i = 0; i < dev->skip; i++) {
		ssize_t n;

		ret = video_cap_wait_vsync(dev, &vsync_seq);
		if (ret) {
			dev_warn_ratelimited(&dev->pdev->dev,
					     "warmup vsync wait failed: %d\n", ret);
			break;
		}

		n = xdma_xfer_submit(dev->xdev, dev->c2h_channel, false, 0,
				     &dev->warmup_sgt, true, 1000);
		if (n < 0) {
			dev_warn_ratelimited(&dev->pdev->dev, "warmup dma failed: %zd\n", n);
			break;
		}
	}

	dev->thread = kthread_run(video_cap_thread_fn, dev, DRV_NAME "_cap");
	if (IS_ERR(dev->thread)) {
		ret = PTR_ERR(dev->thread);
		dev->thread = NULL;
		goto err_disable;
	}

	dev->streaming = true;
	return 0;

err_disable:
	video_cap_enable(dev, false);
	video_cap_warmup_free(dev);
err_irq:
	xdma_user_isr_disable(dev->xdev, dev->user_irq_mask);
	video_cap_return_all_buffers(dev, VB2_BUF_STATE_QUEUED);
	return ret;
}

/* vb2：STREAMOFF 入口（停止线程，关闭 IRQ 与 FPGA 采集）。 */
static void video_cap_stop_streaming(struct vb2_queue *vq)
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vq);

	dev->stopping = true;
	wake_up(&dev->wq);
	wake_up_interruptible(&dev->vsync_wq);

	if (dev->thread) {
		kthread_stop(dev->thread);
		dev->thread = NULL;
	}

	xdma_user_isr_disable(dev->xdev, dev->user_irq_mask);
	video_cap_enable(dev, false);
	video_cap_warmup_free(dev);

	video_cap_return_all_buffers(dev, VB2_BUF_STATE_ERROR);
	dev->streaming = false;

	video_cap_stats_dump(dev, "streamoff");
}

/* vb2 ops 表。 */
static const struct vb2_ops video_cap_vb2_ops = {
	.queue_setup = video_cap_queue_setup,
	.buf_prepare = video_cap_buf_prepare,
	.buf_queue = video_cap_buf_queue,
	.start_streaming = video_cap_start_streaming,
	.stop_streaming = video_cap_stop_streaming,
	.wait_prepare = vb2_ops_wait_prepare,
	.wait_finish = vb2_ops_wait_finish,
};

/* V4L2：上报设备能力。 */
static int video_cap_querycap(struct file *file, void *priv, struct v4l2_capability *cap)
{
	struct video_cap_dev *dev = video_drvdata(file);

	(void)priv;

	strscpy(cap->driver, DRV_NAME, sizeof(cap->driver));
	strscpy(cap->card, "PCIe Video Capture (XDMA core integrated)", sizeof(cap->card));
	strscpy(cap->bus_info, pci_name(dev->pdev), sizeof(cap->bus_info));
	cap->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING | V4L2_CAP_READWRITE;
	cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS;
	return 0;
}

/* V4L2：提供一个固定 input，避免 ffmpeg/ffplay probing 因 G_INPUT/ENUMINPUT 失败。 */
static int video_cap_enum_input(struct file *file, void *priv, struct v4l2_input *inp)
{
	(void)file;
	(void)priv;

	if (inp->index != 0)
		return -EINVAL;

	strscpy(inp->name, "PCIe Video Capture", sizeof(inp->name));
	inp->type = V4L2_INPUT_TYPE_CAMERA;
	inp->audioset = 0;
	inp->tuner = 0;
	inp->std = 0;
	inp->status = 0;
	return 0;
}

static int video_cap_g_input(struct file *file, void *priv, unsigned int *i)
{
	(void)file;
	(void)priv;
	*i = 0;
	return 0;
}

static int video_cap_s_input(struct file *file, void *priv, unsigned int i)
{
	(void)file;
	(void)priv;
	return i == 0 ? 0 : -EINVAL;
}

/* V4L2：枚举支持的采集格式（当前仅 XBGR32）。 */
static int video_cap_enum_fmt_vid_cap(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
	(void)file;
	(void)priv;

	switch (f->index) {
	case 0:
		f->pixelformat = V4L2_PIX_FMT_XBGR32;
		return 0;
	case 1:
		f->pixelformat = V4L2_PIX_FMT_YUYV;
		return 0;
	default:
		return -EINVAL;
	}
}

/* V4L2：获取当前格式。 */
static int video_cap_g_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
	struct video_cap_dev *dev = video_drvdata(file);

	(void)priv;

	f->fmt.pix.width = dev->width;
	f->fmt.pix.height = dev->height;
	f->fmt.pix.pixelformat = dev->pixfmt;
	f->fmt.pix.field = V4L2_FIELD_NONE;
	f->fmt.pix.bytesperline = dev->bytesperline;
	f->fmt.pix.sizeimage = dev->sizeimage;
	f->fmt.pix.colorspace =
		(dev->pixfmt == V4L2_PIX_FMT_YUYV) ? V4L2_COLORSPACE_REC709 : V4L2_COLORSPACE_SRGB;
	return 0;
}

/* V4L2：校验请求格式（当前直接固定到默认分辨率/格式）。 */
static int video_cap_try_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
	u32 pixfmt;

	(void)file;
	(void)priv;

	pixfmt = f->fmt.pix.pixelformat;
	if (!video_cap_pixfmt_supported(pixfmt))
		pixfmt = V4L2_PIX_FMT_XBGR32;

	video_cap_fill_pix_format(&f->fmt.pix, VIDEO_WIDTH_DEFAULT, VIDEO_HEIGHT_DEFAULT, pixfmt);
	return 0;
}

/* V4L2：设置格式（streaming 时禁止修改）。 */
static int video_cap_s_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
	struct video_cap_dev *dev = video_drvdata(file);
	int ret;

	if (dev->streaming)
		return -EBUSY;

	ret = video_cap_try_fmt_vid_cap(file, priv, f);
	if (ret)
		return ret;

	dev->pixfmt = f->fmt.pix.pixelformat;
	dev->width = f->fmt.pix.width;
	dev->height = f->fmt.pix.height;
	dev->bytesperline = f->fmt.pix.bytesperline;
	dev->sizeimage = f->fmt.pix.sizeimage;

	/* 同步到 FPGA：VID_FMT（0x0100） */
	video_cap_apply_hw_format(dev);
	return 0;
}

/* V4L2：固定 FPS 上报（给查询 timeperframe 的应用使用）。 */
static int video_cap_g_parm(struct file *file, void *priv, struct v4l2_streamparm *sp)
{
	(void)file;
	(void)priv;

	if (sp->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;

	sp->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
	sp->parm.capture.timeperframe.numerator = 1;
	sp->parm.capture.timeperframe.denominator = VIDEO_FRAME_RATE_60;
	return 0;
}

static int video_cap_s_parm(struct file *file, void *priv, struct v4l2_streamparm *sp)
{
	return video_cap_g_parm(file, priv, sp);
}

/* V4L2 ioctl 表：大多数 buffer 管理 ioctl 由 vb2 的 helper 处理。 */
static const struct v4l2_ioctl_ops video_cap_ioctl_ops = {
	.vidioc_querycap = video_cap_querycap,

	.vidioc_enum_input = video_cap_enum_input,
	.vidioc_g_input = video_cap_g_input,
	.vidioc_s_input = video_cap_s_input,

	.vidioc_enum_fmt_vid_cap = video_cap_enum_fmt_vid_cap,
	.vidioc_g_fmt_vid_cap = video_cap_g_fmt_vid_cap,
	.vidioc_s_fmt_vid_cap = video_cap_s_fmt_vid_cap,
	.vidioc_try_fmt_vid_cap = video_cap_try_fmt_vid_cap,

	.vidioc_g_parm = video_cap_g_parm,
	.vidioc_s_parm = video_cap_s_parm,

	.vidioc_reqbufs = vb2_ioctl_reqbufs,
	.vidioc_create_bufs = vb2_ioctl_create_bufs,
	.vidioc_prepare_buf = vb2_ioctl_prepare_buf,
	.vidioc_querybuf = vb2_ioctl_querybuf,
	.vidioc_qbuf = vb2_ioctl_qbuf,
	.vidioc_dqbuf = vb2_ioctl_dqbuf,
	.vidioc_expbuf = vb2_ioctl_expbuf,
	.vidioc_streamon = vb2_ioctl_streamon,
	.vidioc_streamoff = vb2_ioctl_streamoff,
};

/* V4L2 file ops：read/poll/mmap/release 交给 vb2 helper。 */
static const struct v4l2_file_operations video_cap_fops = {
	.owner = THIS_MODULE,
	.open = v4l2_fh_open,
	.release = vb2_fop_release,
	.read = vb2_fop_read,
	.poll = vb2_fop_poll,
	.mmap = vb2_fop_mmap,
	.unlocked_ioctl = video_ioctl2,
};

/*
 * 注册 V4L2 设备 + video 节点 + vb2 队列。
 * vb2 的 allocator device 设置为 &pdev->dev，这样 XDMA 可用 dma_mapped=true。
 */
static int video_cap_register_v4l2(struct video_cap_dev *dev)
{
	int ret;

	ret = v4l2_device_register(&dev->pdev->dev, &dev->v4l2_dev);
	if (ret)
		return ret;

	ret = video_cap_init_controls(dev);
	if (ret) {
		dev_err(&dev->pdev->dev, "init controls failed: %d\n", ret);
		goto err_v4l2;
	}

	dev->vb_queue.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	dev->vb_queue.io_modes = VB2_MMAP | VB2_READ | VB2_DMABUF;
	dev->vb_queue.drv_priv = dev;
	dev->vb_queue.buf_struct_size = sizeof(struct video_cap_buffer);
	dev->vb_queue.ops = &video_cap_vb2_ops;
	dev->vb_queue.mem_ops = &vb2_dma_sg_memops;
	dev->vb_queue.timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;
	dev->vb_queue.lock = &dev->lock;
	dev->vb_queue.dev = &dev->pdev->dev;

	ret = vb2_queue_init(&dev->vb_queue);
	if (ret) {
		dev_err(&dev->pdev->dev, "vb2_queue_init failed: %d\n", ret);
		goto err_v4l2;
	}

	dev->vdev.v4l2_dev = &dev->v4l2_dev;
	dev->vdev.fops = &video_cap_fops;
	dev->vdev.ioctl_ops = &video_cap_ioctl_ops;
	dev->vdev.queue = &dev->vb_queue;
	dev->vdev.lock = &dev->lock;
	dev->vdev.release = video_device_release_empty;
	dev->vdev.device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING | V4L2_CAP_READWRITE;

	strscpy(dev->vdev.name, "video_cap", sizeof(dev->vdev.name));
	video_set_drvdata(&dev->vdev, dev);

	ret = video_register_device(&dev->vdev, VFL_TYPE_VIDEO, -1);
	if (ret) {
		dev_err(&dev->pdev->dev, "video_register_device failed: %d\n", ret);
		goto err_ctrls;
	}

	return 0;

err_ctrls:
	video_cap_free_controls(dev);
err_v4l2:
	v4l2_device_unregister(&dev->v4l2_dev);
	return ret;
}

static void video_cap_unregister_v4l2(struct video_cap_dev *dev)
{
	video_unregister_device(&dev->vdev);
	video_cap_free_controls(dev);
	v4l2_device_unregister(&dev->v4l2_dev);
}

/*
 * PCI probe：
 * - 分配并初始化设备结构体
 * - 在该 PCI function 上打开 XDMA core（BAR/IRQ/engine 初始化）
 * - 映射 user BAR 以访问 FPGA 用户寄存器
 * - 注册 VSYNC 的 user IRQ handler
 * - 注册 V4L2 节点（/dev/videoX）
 */
static int video_cap_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct video_cap_dev *dev;
	int user_max = 16;
	int h2c_max = 1;
	int c2h_max = 1;
	int ret;

	(void)id;

	if (irq_index >= XDMA_USER_IRQ_MAX) {
		dev_err(&pdev->dev, "invalid irq_index=%u (max=%u)\n", irq_index,
			XDMA_USER_IRQ_MAX - 1);
		return -EINVAL;
	}

	dev = kzalloc(sizeof(*dev), GFP_KERNEL);
	if (!dev)
		return -ENOMEM;

	dev->pdev = pdev;
	video_cap_stats_init(dev);
	mutex_init(&dev->lock);
	spin_lock_init(&dev->qlock);
	INIT_LIST_HEAD(&dev->buf_list);
	init_waitqueue_head(&dev->wq);
	init_waitqueue_head(&dev->vsync_wq);
	atomic64_set(&dev->vsync_seq, 0);
	dev->vsync_timeout_ms = vsync_timeout_ms;

	dev->width = VIDEO_WIDTH_DEFAULT;
	dev->height = VIDEO_HEIGHT_DEFAULT;
	dev->pixfmt = V4L2_PIX_FMT_XBGR32;
	dev->bytesperline = dev->width * 4;
	dev->sizeimage = dev->width * dev->height * 4;

	dev->test_pattern = test_pattern;
	dev->skip = skip;
	dev->c2h_channel = c2h_channel;
	dev->irq_index = irq_index;

	pci_set_drvdata(pdev, dev);

	dev->xdev = xdma_device_open(DRV_NAME, pdev, &user_max, &h2c_max, &c2h_max);
	if (!dev->xdev) {
		dev_err(&pdev->dev, "xdma_device_open failed\n");
		ret = -ENODEV;
		goto err_free;
	}

	if (dev->c2h_channel >= (unsigned int)c2h_max) {
		dev_err(&pdev->dev, "invalid c2h_channel=%u (max=%d)\n", dev->c2h_channel,
			c2h_max ? (c2h_max - 1) : -1);
		ret = -EINVAL;
		goto err_xdma;
	}
	if (dev->irq_index >= (unsigned int)user_max) {
		dev_err(&pdev->dev, "invalid irq_index=%u (max=%d)\n", dev->irq_index,
			user_max ? (user_max - 1) : -1);
		ret = -EINVAL;
		goto err_xdma;
	}
	dev->user_irq_mask = (u32)BIT(dev->irq_index);

	if (dev->xdev->user_bar_idx < 0 || dev->xdev->user_bar_idx >= XDMA_BAR_NUM ||
	    !dev->xdev->bar[dev->xdev->user_bar_idx]) {
		dev_err(&pdev->dev, "invalid XDMA user BAR idx=%d\n", dev->xdev->user_bar_idx);
		ret = -ENODEV;
		goto err_xdma;
	}
	dev->user_regs = dev->xdev->bar[dev->xdev->user_bar_idx];

	ret = xdma_user_isr_register(dev->xdev, dev->user_irq_mask,
				     video_cap_user_irq_handler, dev);
	if (ret) {
		dev_err(&pdev->dev, "register user irq handler failed: %d\n", ret);
		goto err_xdma;
	}

	ret = video_cap_register_v4l2(dev);
	if (ret)
		goto err_isr;

	dev_info(&pdev->dev, DRV_NAME ": registered /dev/video%d (pci=%s c2h=%u irq=%u)\n",
		 dev->vdev.num, pci_name(pdev), dev->c2h_channel, dev->irq_index);
	video_cap_stats_dump(dev, "probe");
	return 0;

err_isr:
	xdma_user_isr_register(dev->xdev, dev->user_irq_mask, NULL, NULL);
err_xdma:
	xdma_device_close(pdev, dev->xdev);
	dev->xdev = NULL;
err_free:
	video_cap_stats_dump(dev, "probe_failed");
	kfree(dev);
	return ret;
}

/*
 * PCI remove：
 * - 如正在采集则先停采集
 * - 注销 V4L2 节点
 * - 注销 user IRQ handler 并关闭 XDMA core
 */
static void video_cap_pci_remove(struct pci_dev *pdev)
{
	struct video_cap_dev *dev = pci_get_drvdata(pdev);

	if (!dev)
		return;

	if (dev->streaming)
		video_cap_stop_streaming(&dev->vb_queue);

	video_cap_unregister_v4l2(dev);

	if (dev->xdev) {
		xdma_user_isr_disable(dev->xdev, dev->user_irq_mask);
		xdma_user_isr_register(dev->xdev, dev->user_irq_mask, NULL, NULL);
		xdma_device_close(pdev, dev->xdev);
		dev->xdev = NULL;
	}

	video_cap_stats_dump(dev, "remove");
	kfree(dev);
}

static const struct pci_device_id video_cap_pci_ids[] = {
	/* 7028: commonly used in this project; 7018: keep compatibility with older bitstreams */
	{ PCI_DEVICE(0x10ee, 0x7028) },
	{ PCI_DEVICE(0x10ee, 0x7018) },
	{ }
};
MODULE_DEVICE_TABLE(pci, video_cap_pci_ids);

static struct pci_driver video_cap_pci_driver = {
	.name = DRV_NAME,
	.id_table = video_cap_pci_ids,
	.probe = video_cap_pci_probe,
	.remove = video_cap_pci_remove,
};

module_pci_driver(video_cap_pci_driver);

MODULE_DESCRIPTION("Monolithic PCIe V4L2 capture driver (integrated XDMA core)");
MODULE_LICENSE("GPL");
MODULE_SOFTDEP("pre: videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg");
