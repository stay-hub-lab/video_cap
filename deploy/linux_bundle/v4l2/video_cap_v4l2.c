// SPDX-License-Identifier: GPL-2.0

#include <linux/delay.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/kthread.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/timekeeping.h>

#include <linux/videodev2.h>

#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/videobuf2-dma-sg.h>
#include <media/videobuf2-v4l2.h>

/* XDMA headers from this repo (see driver/v4l2/Makefile ccflags-y). */
#include "libxdma_api.h"
#include "xdma_mod.h"

#include "../video_cap_regs.h"

#define DRV_NAME "video_cap_v4l2"

#define VIDEO_WIDTH_DEFAULT  1920
#define VIDEO_HEIGHT_DEFAULT 1080

#ifndef V4L2_PIX_FMT_XBGR32
/* v4l2-ctl shows 'XR24' for 32-bit BGRX. */
#define V4L2_PIX_FMT_XBGR32 v4l2_fourcc('X', 'R', '2', '4')
#endif

/* Step-3: keep a single global instance. */
static struct video_cap_v4l2_dev *g_dev;

struct video_cap_buffer {
	struct vb2_v4l2_buffer vb;
	struct list_head list;
};

struct video_cap_v4l2_dev {
	struct pci_dev *pdev;
	struct xdma_pci_dev *xpdev;
	struct xdma_dev *xdev;
	void __iomem *user_regs;

	struct v4l2_device v4l2_dev;
	struct video_device vdev;
	struct vb2_queue vb_queue;

	struct mutex lock;
	spinlock_t qlock;
	struct list_head buf_list;
	wait_queue_head_t wq;

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

static unsigned short xdma_vendor = 0x10ee;
module_param(xdma_vendor, ushort, 0644);
MODULE_PARM_DESC(xdma_vendor, "XDMA PCI vendor ID (default 0x10ee)");

static unsigned short xdma_device = 0x7018;
module_param(xdma_device, ushort, 0644);
MODULE_PARM_DESC(xdma_device, "XDMA PCI device ID (default 0x7018)");

static unsigned int xdma_index;
module_param(xdma_index, uint, 0644);
MODULE_PARM_DESC(xdma_index, "Select Nth matched XDMA PCI function");

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

static struct pci_dev *video_cap_find_xdma_pdev(u16 vendor, u16 device, unsigned int instance)
{
	struct pci_dev *pdev;
	unsigned int found = 0;

	for_each_pci_dev(pdev) {
		if (vendor && pdev->vendor != vendor)
			continue;
		if (device && pdev->device != device)
			continue;
		if (!pdev->driver || strcmp(pdev->driver->name, "xdma"))
			continue;
		if (found++ != instance)
			continue;

		pci_dev_get(pdev);
		return pdev;
	}

	return NULL;
}

static int video_cap_bind_xdma(struct video_cap_v4l2_dev *dev)
{
	struct xdma_pci_dev *xpdev;
	struct xdma_dev *xdev;

	dev->pdev = video_cap_find_xdma_pdev(xdma_vendor, xdma_device, xdma_index);
	if (!dev->pdev)
		return -ENODEV;

	xpdev = dev_get_drvdata(&dev->pdev->dev);
	if (!xpdev || xpdev->magic != MAGIC_DEVICE) {
		pci_dev_put(dev->pdev);
		dev->pdev = NULL;
		return -ENODEV;
	}

	xdev = (struct xdma_dev *)xpdev->xdev;
	if (!xdev || xdev->magic != MAGIC_DEVICE) {
		pci_dev_put(dev->pdev);
		dev->pdev = NULL;
		return -ENODEV;
	}

	if (dev->c2h_channel >= xdev->c2h_channel_max) {
		pci_dev_put(dev->pdev);
		dev->pdev = NULL;
		return -EINVAL;
	}
	if (dev->irq_index >= (unsigned int)xdev->user_max) {
		pci_dev_put(dev->pdev);
		dev->pdev = NULL;
		return -EINVAL;
	}

	if (xdev->user_bar_idx < 0 || xdev->user_bar_idx >= XDMA_BAR_NUM ||
	    !xdev->bar[xdev->user_bar_idx]) {
		pci_dev_put(dev->pdev);
		dev->pdev = NULL;
		return -ENODEV;
	}

	dev->xpdev = xpdev;
	dev->xdev = xdev;
	dev->user_regs = xdev->bar[xdev->user_bar_idx];

	return 0;
}

static void video_cap_unbind_xdma(struct video_cap_v4l2_dev *dev)
{
	if (dev->pdev) {
		pci_dev_put(dev->pdev);
		dev->pdev = NULL;
	}
	dev->xpdev = NULL;
	dev->xdev = NULL;
	dev->user_regs = NULL;
}

static void video_cap_reg_write32(struct video_cap_v4l2_dev *dev, u32 off, u32 val)
{
	iowrite32(val, (u8 __iomem *)dev->user_regs + off);
}

static int video_cap_enable(struct video_cap_v4l2_dev *dev, bool enable)
{
	u32 ctrl = 0;

	if (!dev->user_regs)
		return -ENODEV;

	if (enable) {
		ctrl |= CTRL_ENABLE;
		if (dev->test_pattern)
			ctrl |= CTRL_TEST_MODE;
	}

	video_cap_reg_write32(dev, REG_CONTROL, ctrl);
	return 0;
}

static int video_cap_wait_vsync(struct video_cap_v4l2_dev *dev)
{
	struct xdma_user_irq *user_irq;
	unsigned long flags;
	u32 events_user;
	long rv;

	if (!dev->xdev)
		return -ENODEV;

	user_irq = &dev->xdev->user_irq[dev->irq_index];
	rv = wait_event_interruptible_timeout(user_irq->events_wq,
					      dev->stopping || user_irq->events_irq != 0,
					      msecs_to_jiffies(1000));
	if (rv < 0)
		return (int)rv;
	if (rv == 0)
		return -ETIMEDOUT;
	if (dev->stopping)
		return -EINTR;

	spin_lock_irqsave(&user_irq->events_lock, flags);
	events_user = user_irq->events_irq;
	user_irq->events_irq = 0;
	spin_unlock_irqrestore(&user_irq->events_lock, flags);

	(void)events_user;
	return 0;
}

static int video_cap_dma_read_frame(struct video_cap_v4l2_dev *dev, struct vb2_buffer *vb)
{
	struct sg_table *sgt;
	struct scatterlist *sg, *last_sg = NULL;
	ssize_t n;
	u32 orig_nents;
	u32 used_nents;
	u32 last_orig_len = 0;
	u32 last_orig_dma_len = 0;
	size_t remaining;

	sgt = vb2_dma_sg_plane_desc(vb, 0);
	if (!sgt)
		return -EFAULT;

	/*
	 * vb2-dma-sg provides an sg_table already mapped for vb2_queue.dev
	 * (which we set to &pdev->dev), so pass dma_mapped=true.
	 */
	orig_nents = sgt->nents;
	remaining = dev->sizeimage;
	sg = sgt->sgl;
	for (used_nents = 0; used_nents < orig_nents && sg; used_nents++, sg = sg_next(sg)) {
		u32 seg_len = sg_dma_len(sg);

		if (seg_len >= remaining) {
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

	n = xdma_xfer_submit(dev->xdev, dev->c2h_channel, false, 0, sgt, true, 1000);

	/* Restore sg_table for vb2 reuse */
	sgt->nents = orig_nents;
	if (last_sg) {
		last_sg->length = last_orig_len;
		sg_dma_len(last_sg) = last_orig_dma_len;
	}

	if (n < 0)
		return (int)n;
	if (n != dev->sizeimage)
		return -EIO;
	return 0;
}

static int video_cap_warmup_init(struct video_cap_v4l2_dev *dev)
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

static void video_cap_warmup_free(struct video_cap_v4l2_dev *dev)
{
	if (dev->warmup_buf) {
		dma_free_coherent(&dev->pdev->dev, dev->sizeimage, dev->warmup_buf,
				  dev->warmup_dma);
		dev->warmup_buf = NULL;
	}
	dev->warmup_inited = false;
}

static struct video_cap_buffer *video_cap_next_buf(struct video_cap_v4l2_dev *dev)
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

static void video_cap_return_all_buffers(struct video_cap_v4l2_dev *dev,
					enum vb2_buffer_state state)
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

static int video_cap_thread_fn(void *data)
{
	struct video_cap_v4l2_dev *dev = data;

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

		ret = video_cap_wait_vsync(dev);
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
		if (ret && ret != -ERESTARTSYS)
			dev_err(&dev->pdev->dev, "capture error: %d\n", ret);
	}

	return 0;
}

static int video_cap_queue_setup(struct vb2_queue *vq,
				 unsigned int *nbuffers,
				 unsigned int *nplanes,
				 unsigned int sizes[],
				 struct device *alloc_devs[])
{
	struct video_cap_v4l2_dev *dev = vb2_get_drv_priv(vq);

	*nplanes = 1;
	sizes[0] = dev->sizeimage;

	if (*nbuffers < 4)
		*nbuffers = 4;

	return 0;
}

static int video_cap_buf_prepare(struct vb2_buffer *vb)
{
	struct video_cap_v4l2_dev *dev = vb2_get_drv_priv(vb->vb2_queue);

	if (vb2_plane_size(vb, 0) < dev->sizeimage)
		return -EINVAL;

	vb2_set_plane_payload(vb, 0, dev->sizeimage);
	return 0;
}

static void video_cap_buf_queue(struct vb2_buffer *vb)
{
	struct video_cap_v4l2_dev *dev = vb2_get_drv_priv(vb->vb2_queue);
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
	struct video_cap_buffer *buf = container_of(vbuf, struct video_cap_buffer, vb);
	unsigned long flags;

	spin_lock_irqsave(&dev->qlock, flags);
	list_add_tail(&buf->list, &dev->buf_list);
	spin_unlock_irqrestore(&dev->qlock, flags);

	wake_up(&dev->wq);
}

static int video_cap_start_streaming(struct vb2_queue *vq, unsigned int count)
{
	struct video_cap_v4l2_dev *dev = vb2_get_drv_priv(vq);
	unsigned int i;
	int ret;

	(void)count;

	dev->stopping = false;
	dev->sequence = 0;

	ret = video_cap_enable(dev, true);
	if (ret)
		goto err_q;

	ret = video_cap_warmup_init(dev);
	if (ret)
		goto err_disable;

	/* Optionally discard N complete frames to align the stream. */
	for (i = 0; i < dev->skip; i++) {
		ssize_t n;

		ret = video_cap_wait_vsync(dev);
		if (ret)
			break;

		n = xdma_xfer_submit(dev->xdev, dev->c2h_channel, false, 0,
				     &dev->warmup_sgt, true, 1000);
		if (n < 0)
			break;
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
err_q:
	video_cap_return_all_buffers(dev, VB2_BUF_STATE_QUEUED);
	return ret;
}

static void video_cap_stop_streaming(struct vb2_queue *vq)
{
	struct video_cap_v4l2_dev *dev = vb2_get_drv_priv(vq);

	dev->stopping = true;
	wake_up(&dev->wq);

	if (dev->thread) {
		kthread_stop(dev->thread);
		dev->thread = NULL;
	}

	video_cap_enable(dev, false);
	video_cap_warmup_free(dev);

	video_cap_return_all_buffers(dev, VB2_BUF_STATE_ERROR);
	dev->streaming = false;
}

static const struct vb2_ops video_cap_vb2_ops = {
	.queue_setup = video_cap_queue_setup,
	.buf_prepare = video_cap_buf_prepare,
	.buf_queue = video_cap_buf_queue,
	.start_streaming = video_cap_start_streaming,
	.stop_streaming = video_cap_stop_streaming,
	.wait_prepare = vb2_ops_wait_prepare,
	.wait_finish = vb2_ops_wait_finish,
};

static int video_cap_querycap(struct file *file, void *priv,
			      struct v4l2_capability *cap)
{
	strscpy(cap->driver, DRV_NAME, sizeof(cap->driver));
	strscpy(cap->card, "PCIe Video Capture (XDMA)", sizeof(cap->card));
	strscpy(cap->bus_info, "platform:xdma", sizeof(cap->bus_info));
	cap->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING | V4L2_CAP_READWRITE;
	cap->capabilities = cap->device_caps | V4L2_CAP_DEVICE_CAPS;
	return 0;
}

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

static int video_cap_enum_fmt_vid_cap(struct file *file, void *priv,
				      struct v4l2_fmtdesc *f)
{
	if (f->index != 0)
		return -EINVAL;

	f->pixelformat = V4L2_PIX_FMT_XBGR32;
	return 0;
}

static int video_cap_g_fmt_vid_cap(struct file *file, void *priv,
				   struct v4l2_format *f)
{
	struct video_cap_v4l2_dev *dev = video_drvdata(file);

	f->fmt.pix.width = dev->width;
	f->fmt.pix.height = dev->height;
	f->fmt.pix.pixelformat = dev->pixfmt;
	f->fmt.pix.field = V4L2_FIELD_NONE;
	f->fmt.pix.bytesperline = dev->bytesperline;
	f->fmt.pix.sizeimage = dev->sizeimage;
	f->fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
	return 0;
}

static int video_cap_try_fmt_vid_cap(struct file *file, void *priv,
				     struct v4l2_format *f)
{
	f->fmt.pix.width = VIDEO_WIDTH_DEFAULT;
	f->fmt.pix.height = VIDEO_HEIGHT_DEFAULT;
	f->fmt.pix.pixelformat = V4L2_PIX_FMT_XBGR32;
	f->fmt.pix.field = V4L2_FIELD_NONE;
	f->fmt.pix.bytesperline = VIDEO_WIDTH_DEFAULT * 4;
	f->fmt.pix.sizeimage = VIDEO_WIDTH_DEFAULT * VIDEO_HEIGHT_DEFAULT * 4;
	f->fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
	return 0;
}

static int video_cap_s_fmt_vid_cap(struct file *file, void *priv,
				   struct v4l2_format *f)
{
	struct video_cap_v4l2_dev *dev = video_drvdata(file);
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
	return 0;
}

static int video_cap_g_parm(struct file *file, void *priv, struct v4l2_streamparm *sp)
{
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

static const struct v4l2_file_operations video_cap_fops = {
	.owner = THIS_MODULE,
	.open = v4l2_fh_open,
	.release = vb2_fop_release,
	.read = vb2_fop_read,
	.poll = vb2_fop_poll,
	.mmap = vb2_fop_mmap,
	.unlocked_ioctl = video_ioctl2,
};

static int __init video_cap_v4l2_init(void)
{
	struct video_cap_v4l2_dev *dev;
	int ret;

	if (g_dev)
		return -EBUSY;

	dev = kzalloc(sizeof(*dev), GFP_KERNEL);
	if (!dev)
		return -ENOMEM;

	mutex_init(&dev->lock);
	spin_lock_init(&dev->qlock);
	INIT_LIST_HEAD(&dev->buf_list);
	init_waitqueue_head(&dev->wq);

	dev->width = VIDEO_WIDTH_DEFAULT;
	dev->height = VIDEO_HEIGHT_DEFAULT;
	dev->pixfmt = V4L2_PIX_FMT_XBGR32;
	dev->bytesperline = dev->width * 4;
	dev->sizeimage = dev->width * dev->height * 4;

	dev->test_pattern = test_pattern;
	dev->skip = skip;
	dev->c2h_channel = c2h_channel;
	dev->irq_index = irq_index;

	ret = video_cap_bind_xdma(dev);
	if (ret)
		goto err_free;

	ret = v4l2_device_register(&dev->pdev->dev, &dev->v4l2_dev);
	if (ret)
		goto err_xdma;

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
	if (ret)
		goto err_v4l2;

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
	if (ret)
		goto err_v4l2;

	g_dev = dev;
	pr_info(DRV_NAME ": registered /dev/video%d (pci=%s c2h=%u irq=%u)\n",
		dev->vdev.num, dev_name(&dev->pdev->dev), dev->c2h_channel,
		dev->irq_index);
	return 0;

err_v4l2:
	v4l2_device_unregister(&dev->v4l2_dev);
err_xdma:
	video_cap_unbind_xdma(dev);
err_free:
	kfree(dev);
	return ret;
}

static void __exit video_cap_v4l2_exit(void)
{
	struct video_cap_v4l2_dev *dev = g_dev;

	if (!dev)
		return;
	g_dev = NULL;

	if (dev->streaming)
		video_cap_stop_streaming(&dev->vb_queue);

	video_unregister_device(&dev->vdev);
	v4l2_device_unregister(&dev->v4l2_dev);
	video_cap_unbind_xdma(dev);
	kfree(dev);
}

module_init(video_cap_v4l2_init);
module_exit(video_cap_v4l2_exit);

MODULE_DESCRIPTION("V4L2 capture for XDMA C2H stream (vb2-dma-sg + xdma_xfer_submit)");
MODULE_LICENSE("GPL");
MODULE_SOFTDEP("pre: xdma videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg");
