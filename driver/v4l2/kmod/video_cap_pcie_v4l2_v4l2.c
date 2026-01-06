// SPDX-License-Identifier: GPL-2.0

/*
 * video_cap_pcie_v4l2_v4l2.c
 *
 * 这一文件只放 V4L2 侧的 glue：
 * - querycap / enum_fmt / g/s/try_fmt / g/s_parm
 * - 自定义 controls（test_pattern/skip/vsync_timeout 等）
 * - 注册 video_device 与 vb2_queue
 *
 * 当前实现为了 bring-up 简化：TRY_FMT/S_FMT 会固定到默认分辨率（1080p），
 * 不支持任意分辨率切换；后续再按需要扩展。
 */

#include <linux/limits.h>
#include <linux/module.h>

#include <media/v4l2-ioctl.h>
#include <media/videobuf2-dma-sg.h>

#include "video_cap_pcie_v4l2_priv.h"

/* 判断驱动支持的像素格式（供 enum/try/s_fmt 使用） */
bool video_cap_pixfmt_supported(u32 pixfmt)
{
	switch (pixfmt) {
	case V4L2_PIX_FMT_XBGR32: /* ffplay/v4l2-ctl 显示 fourcc 'XR24'，对应像素格式 bgr0 */
	case V4L2_PIX_FMT_YUYV:   /* fourcc 'YUYV'，对应像素格式 yuyv422 */
		return true;
	default:
		return false;
	}
}

/* 填充 v4l2_pix_format 的常用字段（bytesperline/sizeimage/colorspace 等） */
void video_cap_fill_pix_format(struct v4l2_pix_format *pix, u32 width, u32 height, u32 pixfmt)
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
 * V4L2 ctrl 回调：设置自定义控件。
 * 说明：
 * - 当前为了简化状态机，streaming 期间禁止修改（返回 -EBUSY）
 */
/* 函数：V4L2 ctrl 设置回调（s_ctrl） */
static int video_cap_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct video_cap_dev *dev = container_of(ctrl->handler, struct video_cap_dev, ctrl_handler);

	/*
	 * 为了简化状态机，streaming 期间禁止修改这些参数。
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

/* V4L2 ctrl 回调：读取只读/volatile 统计项 */
static int video_cap_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
	struct video_cap_dev *dev = container_of(ctrl->handler, struct video_cap_dev, ctrl_handler);
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

/* 创建一个自定义 ctrl（封装 v4l2_ctrl_new_custom） */
static struct v4l2_ctrl *video_cap_new_ctrl(struct video_cap_dev *dev, const struct v4l2_ctrl_config *cfg)
{
	struct v4l2_ctrl *ctrl;

	ctrl = v4l2_ctrl_new_custom(&dev->ctrl_handler, cfg, NULL);
	if (dev->ctrl_handler.error)
		dev_err(&dev->pdev->dev, "create ctrl '%s'(0x%x) failed: %d\n",
			cfg->name ? cfg->name : "?", cfg->id, dev->ctrl_handler.error);
	return ctrl;
}

/*
 * 初始化该 /dev/videoX 的 controls：
 * - test_pattern/skip/vsync_timeout_ms
 * - 只读统计：vsync_timeout/dma_error
 */
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

	/* VSYNC 等待超时：调试现场环境可按需调小（低延时场景建议 30~200ms） */
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
		dev->ctrl_stat_vsync_timeout->flags |=
			V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE;

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

	dev->vdev.ctrl_handler = &dev->ctrl_handler;
	return 0;
}

/* 释放 controls（对应 video_cap_init_controls） */
static void video_cap_free_controls(struct video_cap_dev *dev)
{
	v4l2_ctrl_handler_free(&dev->ctrl_handler);
	dev->vdev.ctrl_handler = NULL;
}

/* V4L2：上报设备能力 */
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

/* V4L2：枚举 input（这里固定只有 index=0，一个虚拟输入） */
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

/* V4L2：获取当前 input（固定为 0） */
static int video_cap_g_input(struct file *file, void *priv, unsigned int *i)
{
	(void)file;
	(void)priv;
	*i = 0;
	return 0;
}

/* V4L2：设置 input（只允许 0） */
static int video_cap_s_input(struct file *file, void *priv, unsigned int i)
{
	(void)file;
	(void)priv;
	return i == 0 ? 0 : -EINVAL;
}

/* V4L2：枚举支持的像素格式列表（XR24 / YUYV） */
static int video_cap_enum_fmt_vid_cap(struct file *file, void *priv, struct v4l2_fmtdesc *f)
{
	(void)file;
	(void)priv;

	switch (f->index) {
	case 0:
		f->pixelformat = V4L2_PIX_FMT_XBGR32;
		strscpy(f->description, "32-bit BGRX", sizeof(f->description));
		return 0;
	case 1:
		f->pixelformat = V4L2_PIX_FMT_YUYV;
		strscpy(f->description, "YUYV 4:2:2", sizeof(f->description));
		return 0;
	default:
		return -EINVAL;
	}
}

/* V4L2：读取当前格式 */
static int video_cap_g_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
	struct video_cap_dev *dev = video_drvdata(file);

	(void)priv;

	video_cap_fill_pix_format(&f->fmt.pix, dev->width, dev->height, dev->pixfmt);
	return 0;
}

/*
 * V4L2：校验/修正用户请求格式。
 * 当前策略：只允许切换像素格式，分辨率固定为默认值（1080p）。
 */
/* 函数：V4L2 try_fmt 回调（校验/修正用户请求格式） */
static int video_cap_try_fmt_vid_cap(struct file *file, void *priv, struct v4l2_format *f)
{
	u32 pixfmt;

	(void)file;
	(void)priv;

	pixfmt = f->fmt.pix.pixelformat;
	if (!video_cap_pixfmt_supported(pixfmt))
		pixfmt = V4L2_PIX_FMT_XBGR32;

	/* 当前驱动直接把请求格式收敛到默认分辨率，避免与 FPGA 侧能力不匹配 */
	video_cap_fill_pix_format(&f->fmt.pix, VIDEO_WIDTH_DEFAULT, VIDEO_HEIGHT_DEFAULT, pixfmt);
	return 0;
}

/*
 * V4L2：设置格式（streaming 期间禁止）。
 * 这里会把选择的像素格式同步到 FPGA（VID_FORMAT）。
 */
/* 函数：V4L2 s_fmt 回调（设置当前格式，并同步到 FPGA） */
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

	/* 同步到 FPGA：VID_FMT */
	video_cap_apply_hw_format(dev);
	return 0;
}

/* V4L2：上报帧率信息（固定 60fps，仅用于查询 timeperframe 的应用） */
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

/* V4L2：设置帧率（当前实现固定，直接回到 g_parm） */
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

/*
 * 注册一个 /dev/videoX：
 * - 初始化 controls
 * - 初始化 vb2_queue（mem_ops=vb2_dma_sg_memops）
 * - 注册 video_device
 */
int video_cap_register_v4l2(struct video_cap_dev *dev)
{
	int ret;

	ret = video_cap_init_controls(dev);
	if (ret) {
		dev_err(&dev->pdev->dev, "init controls failed: %d\n", ret);
		return ret;
	}

	/*
	 * vb2_queue 初始化要点：
	 * - mem_ops=vb2_dma_sg_memops：分配 sg buffer，方便直接交给 XDMA
	 * - vb_queue.dev=&pdev->dev：确保 vb2 以 PCIe 设备为 DMA 设备做映射
	 */
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
		goto err_ctrls;
	}

	dev->vdev.v4l2_dev = &dev->multi->v4l2_dev;
	dev->vdev.fops = &video_cap_fops;
	dev->vdev.ioctl_ops = &video_cap_ioctl_ops;
	dev->vdev.queue = &dev->vb_queue;
	dev->vdev.lock = &dev->lock;
	dev->vdev.release = video_device_release_empty;
	dev->vdev.device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING | V4L2_CAP_READWRITE;

	/* 让 video node 名字带上 c2h 通道号，便于多通道排查 */
	snprintf(dev->vdev.name, sizeof(dev->vdev.name), "video_cap_c2h%u", dev->c2h_channel);
	video_set_drvdata(&dev->vdev, dev);

	ret = video_register_device(&dev->vdev, VFL_TYPE_VIDEO, -1);
	if (ret) {
		dev_err(&dev->pdev->dev, "video_register_device failed: %d\n", ret);
		goto err_ctrls;
	}

	return 0;

err_ctrls:
	video_cap_free_controls(dev);
	return ret;
}

/* 注销 /dev/videoX 并释放 controls */
void video_cap_unregister_v4l2(struct video_cap_dev *dev)
{
	video_unregister_device(&dev->vdev);
	video_cap_free_controls(dev);
}
