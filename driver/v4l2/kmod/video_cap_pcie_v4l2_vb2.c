// SPDX-License-Identifier: GPL-2.0

/*
 * video_cap_pcie_v4l2_vb2.c
 *
 * 这一文件承载“采集线程 + vb2 队列”的主体逻辑：
 * - VSYNC IRQ：只做计数 + 唤醒，尽量短
 * - 采集线程：等 QBUF -> 等 VSYNC -> 发起一次整帧 DMA -> DONE/ERROR
 * - vb2 ops：queue_setup/buf_queue/STREAMON/STREAMOFF
 *
 * 注意：当前是“按帧 DMA”模型（每次 DMA dev->sizeimage 字节）。
 */

#include <linux/dma-mapping.h>
#include <linux/jiffies.h>
#include <linux/mm.h>

#include <media/videobuf2-dma-sg.h>

#include "libxdma_api.h"

#include "video_cap_pcie_v4l2_priv.h"

/*
 * VSYNC 中断处理函数（XDMA 的 user IRQ）。
 * 尽量保持 ISR 最小化：只记录“来了一个 VSYNC”，并唤醒采集线程。
 */
/*
 * VSYNC 的 user IRQ ISR。
 * 设计要点：
 * - ISR 尽量短：只做计数 + 唤醒 waitqueue
 * - 不在 ISR 里做寄存器读写/提交 DMA，避免增加中断抖动
 */
/* 函数：VSYNC user IRQ 中断处理（只做计数+唤醒） */
irqreturn_t video_cap_user_irq_handler(int user, void *data)
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
/*
 * 等待“下一次 VSYNC”到来。
 * - last_seq 是调用方维护的“上次看到的序号”
 * - 返回 0 表示等到了新的 VSYNC；<0 表示 stop/timeout/信号中断等
 */
/* 函数：等待下一次 VSYNC（支持 timeout/stop） */
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
/*
 * 提交一次整帧 DMA（C2H）把数据写入 vb2 buffer。
 * 关键点：
 * - vb2-dma-sg 的 sg_table 通常页对齐，总长度可能 > sizeimage
 * - FPGA 实际每帧只输出 sizeimage 字节，因此这里裁剪最后一个 sg 段
 */
/* 函数：提交一次整帧 DMA，把数据写入 vb2 buffer */
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
	 * vb2-dma-sg buffers are often page-aligned, so the sg_table total DMA
	 * length can be larger than dev->sizeimage. The FPGA only produces
	 * sizeimage bytes per frame, so cap the DMA transfer length to exactly
	 * dev->sizeimage to avoid timeouts/short frames.
	 */
	/* 中文说明：vb2 分配的 buffer 往往页对齐，sg_table 总长度可能大于 sizeimage。
	 * FPGA 实际每帧只输出 sizeimage 字节，所以这里把最后一个 sg 段裁剪到精确长度，
	 * 避免 XDMA 继续等待“多出来的页尾”导致 DMA timeout/短帧。
	 */
	atomic64_inc(&dev->stats.dma_submit);
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
 * 使能采集后先读并丢 N 帧，用于对齐流水线/稳定输出。
 * 这里分配一块 coherent 的临时缓冲区，并封装成单 entry 的 sg_table。
 */
/*
 * warm-up 初始化：分配临时 DMA buffer，用于 STREAMON 后丢弃 N 帧。
 * 目的：让上游/流水线稳定，避免第一帧/前几帧出现不完整或脏数据。
 */
/* 函数：warm-up 初始化（丢弃前 N 帧） */
static int video_cap_warmup_init(struct video_cap_dev *dev)
{
	if (!dev->skip || dev->warmup_inited)
		return 0;

	dev->warmup_buf = dma_alloc_coherent(&dev->pdev->dev, dev->sizeimage, &dev->warmup_dma,
					     GFP_KERNEL);
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

/* warm-up 资源释放 */
static void video_cap_warmup_free(struct video_cap_dev *dev)
{
	if (dev->warmup_buf) {
		dma_free_coherent(&dev->pdev->dev, dev->sizeimage, dev->warmup_buf,
				  dev->warmup_dma);
		dev->warmup_buf = NULL;
	}
	dev->warmup_inited = false;
}

/* 从队列中取出下一个待填充的 vb2 buffer（线程上下文） */
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

/*
 * 把当前所有已排队但未完成的 buffer 以指定状态返回给 vb2。
 * 常用于：STREAMOFF / 错误退出 / probe/cleanup。
 */
/* 函数：按状态归还所有未完成的 vb2 buffers */
static void video_cap_return_all_buffers(struct video_cap_dev *dev, enum vb2_buffer_state state)
{
	LIST_HEAD(list);
	unsigned long flags;

	spin_lock_irqsave(&dev->qlock, flags);
	list_splice_init(&dev->buf_list, &list);
	spin_unlock_irqrestore(&dev->qlock, flags);

	while (!list_empty(&list)) {
		struct video_cap_buffer *buf = list_first_entry(&list, struct video_cap_buffer, list);

		list_del(&buf->list);
		vb2_buffer_done(&buf->vb.vb2_buf, state);
	}
}

/*
 * 采集线程主循环：
 * 1) 等待用户态 QBUF（buf_list 非空）
 * 2) 等待 VSYNC（对齐到帧边界）
 * 3) 提交一次整帧 DMA，把 FPGA 输出写入该 buffer
 * 4) 完成后 vb2_buffer_done(DONE)，失败则 ERROR
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

static int video_cap_queue_setup(struct vb2_queue *vq, unsigned int *nbuffers, unsigned int *nplanes,
				 unsigned int sizes[], struct device *alloc_devs[])
{
	/* vb2 回调：告诉 vb2 我们需要多少 plane，以及每个 buffer 的大小 */
	struct video_cap_dev *dev = vb2_get_drv_priv(vq);

	*nplanes = 1;
	sizes[0] = dev->sizeimage;

	/* 这里强制最少 4 个 buffer（更稳，但会增加系统整体缓冲；低延时可后续再优化） */
	if (*nbuffers < 4)
		*nbuffers = 4;

	return 0;
}

/* vb2 回调：准备 buffer（检查大小并设置 payload） */
static int video_cap_buf_prepare(struct vb2_buffer *vb)
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vb->vb2_queue);

	if (vb2_plane_size(vb, 0) < dev->sizeimage)
		return -EINVAL;

	vb2_set_plane_payload(vb, 0, dev->sizeimage);
	return 0;
}

/* vb2 回调：用户态 QBUF 之后，把 buffer 放入待处理队列并唤醒采集线程 */
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
 * vb2 回调：STREAMON
 * - enable user IRQ（VSYNC）
 * - enable FPGA capture
 * - 可选 warm-up 丢弃 N 帧
 * - 启动采集线程
 */
static int video_cap_start_streaming(struct vb2_queue *vq, unsigned int count)
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vq);
	unsigned int i;
	int ret;
	u64 vsync_seq;

	(void)count;

	/*
	 * 兼容模式：如果 FPGA 还是全局寄存器（没有 per-channel regs），多路同时 STREAMON
	 * 会互相覆盖 CTRL/VID_FORMAT，所以只能互斥。
	 * 一旦 FPGA 实现 REG_CAPS + per-channel block，则允许并发采集。
	 */
	if (!dev->multi->has_per_ch_regs) {
		mutex_lock(&dev->multi->hw_lock);
		if (dev->multi->active_stream && dev->multi->active_stream != dev) {
			mutex_unlock(&dev->multi->hw_lock);
			video_cap_return_all_buffers(dev, VB2_BUF_STATE_QUEUED);
			return -EBUSY;
		}
		dev->multi->active_stream = dev;
		mutex_unlock(&dev->multi->hw_lock);
	}

	dev->stopping = false;
	dev->sequence = 0;
	atomic64_set(&dev->vsync_seq, 0);
	vsync_seq = 0;

	/* 打开 VSYNC user IRQ（仅对本路绑定的 bit 生效） */
	ret = xdma_user_isr_enable(dev->xdev, dev->user_irq_mask);
	if (ret) {
		dev_err(&dev->pdev->dev, "enable user irq failed: %d\n", ret);
		video_cap_return_all_buffers(dev, VB2_BUF_STATE_QUEUED);
		goto err_active;
	}

	/* 使能 FPGA 采集（写 CTRL/VID_FORMAT 等寄存器） */
	ret = video_cap_enable(dev, true);
	if (ret)
		goto err_irq;

	/* warm-up 缓冲区准备（如果 skip=0 则不会分配） */
	ret = video_cap_warmup_init(dev);
	if (ret)
		goto err_disable;

	for (i = 0; i < dev->skip; i++) {
		ssize_t n;

		ret = video_cap_wait_vsync(dev, &vsync_seq);
		if (ret) {
			dev_warn_ratelimited(&dev->pdev->dev, "warmup vsync wait failed: %d\n",
					     ret);
			break;
		}

		n = xdma_xfer_submit(dev->xdev, dev->c2h_channel, false, 0, &dev->warmup_sgt, true,
				     1000);
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
	/* 注意顺序：先关采集，再释放 warm-up 资源 */
	video_cap_enable(dev, false);
	video_cap_warmup_free(dev);
err_irq:
	/* 如果中途失败，需要把 IRQ 关掉避免空转唤醒 */
	xdma_user_isr_disable(dev->xdev, dev->user_irq_mask);
	video_cap_return_all_buffers(dev, VB2_BUF_STATE_QUEUED);
err_active:
	if (!dev->multi->has_per_ch_regs) {
		mutex_lock(&dev->multi->hw_lock);
		if (dev->multi->active_stream == dev)
			dev->multi->active_stream = NULL;
		mutex_unlock(&dev->multi->hw_lock);
	}
	return ret;
}

/*
 * vb2 回调：STREAMOFF
 * - 停止采集线程
 * - disable user IRQ
 * - disable FPGA capture
 * - 归还所有未完成 buffer（ERROR）
 */
/* 函数：vb2 STREAMOFF（停线程/关 IRQ/归还 buffers） */
void video_cap_stop_streaming(struct vb2_queue *vq)
{
	struct video_cap_dev *dev = vb2_get_drv_priv(vq);

	/* 通知线程退出，并唤醒所有 waitqueue 避免卡死 */
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

	if (!dev->multi->has_per_ch_regs) {
		mutex_lock(&dev->multi->hw_lock);
		if (dev->multi->active_stream == dev)
			dev->multi->active_stream = NULL;
		mutex_unlock(&dev->multi->hw_lock);
	}

	video_cap_stats_dump(dev, "streamoff");
}

const struct vb2_ops video_cap_vb2_ops = {
	.queue_setup = video_cap_queue_setup,
	.buf_prepare = video_cap_buf_prepare,
	.buf_queue = video_cap_buf_queue,
	.start_streaming = video_cap_start_streaming,
	.stop_streaming = video_cap_stop_streaming,
	.wait_prepare = vb2_ops_wait_prepare,
	.wait_finish = vb2_ops_wait_finish,
};
