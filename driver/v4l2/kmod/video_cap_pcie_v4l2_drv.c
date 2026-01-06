// SPDX-License-Identifier: GPL-2.0
/*
 * PlanB 单模块 PCIe 视频采集驱动。
 *
 * 本模块做什么：
 * - 把 Xilinx XDMA 的核心源代码直接编译进同一个 .ko（单模块集成），不再依赖系统里单独加载的 xdma.ko。
 * - 通过 V4L2 暴露一个未压缩的视频采集设备：/dev/videoX
 *
 * 数据通路（每帧）：
 *   VSYNC（user IRQ）-> 唤醒采集线程 -> XDMA C2H DMA 写入 vb2 buffer
 *   -> vb2_buffer_done() -> 用户态 mmap/read 取帧
 *
 * 说明：
 * - 需要 FPGA bitstream 把 VSYNC/帧边界信号连接到 XDMA 的某一路 user IRQ。
 */

#include <linux/bitops.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/slab.h>

#include "libxdma.h"
#include "libxdma_api.h"

#include "video_cap_pcie_v4l2_priv.h"

/* 模块参数：方便 bring-up；后续可迁移到 V4L2 controls（运行时可调，不必重载模块） */
static unsigned int c2h_channel;
module_param(c2h_channel, uint, 0644);
MODULE_PARM_DESC(c2h_channel, "First XDMA C2H channel index (base, default 0)");

static unsigned int irq_index = 1;
module_param(irq_index, uint, 0644);
MODULE_PARM_DESC(irq_index, "First XDMA user IRQ index used as VSYNC (base, default 1)");

static unsigned int num_channels;
module_param(num_channels, uint, 0644);
MODULE_PARM_DESC(num_channels, "Number of C2H channels to expose as /dev/videoX (0 = auto from XDMA)");

static bool test_pattern = true;
module_param(test_pattern, bool, 0644);
MODULE_PARM_DESC(test_pattern, "Enable test pattern (color bar) in FPGA");

static unsigned int skip;
module_param(skip, uint, 0644);
MODULE_PARM_DESC(skip, "Discard N frames after enable (warm-up)");

static unsigned int vsync_timeout_ms = 1000;
module_param(vsync_timeout_ms, uint, 0644);
MODULE_PARM_DESC(vsync_timeout_ms, "VSYNC wait timeout in ms (default 1000)");

/*
 * 多通道映射约定：
 * - 第 i 路 /dev/videoX 使用：c2h_channel + i
 * - 第 i 路 VSYNC IRQ bit 使用：irq_index + i
 *
 * 示例：irq_index=1 时，ch0 用 user irq[1]，ch1 用 user irq[2]。
 */
/*
 * PCI probe：
 * - 打开 XDMA core（xdma_device_open）
 * - 找到 XDMA user BAR 映射地址（FPGA user_regs）
 * - 根据 num_channels/c2h_max/user_max 创建多个 /dev/videoX
 * - 为每个 /dev/videoX 注册对应的 VSYNC user IRQ handler
 */
static int video_cap_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct video_cap_multi *m;
	struct video_cap_dev *dev = NULL;
	/*
	 * Important:
	 * xdma_device_open() treats these as *limits* for engine probing.
	 * Pass 0 to let XDMA auto-detect up to XDMA_CHANNEL_NUM_MAX.
	 */
	int user_max = 0;
	int h2c_max = 0;
	int c2h_max = 0;
	unsigned int want;
	unsigned int i;
	int ret = 0;
	bool v4l2_registered = false;

	(void)id;

	if (irq_index >= XDMA_USER_IRQ_MAX) {
		dev_err(&pdev->dev, "invalid irq_index=%u (max=%u)\n", irq_index,
			XDMA_USER_IRQ_MAX - 1);
		return -EINVAL;
	}

	m = kzalloc(sizeof(*m), GFP_KERNEL);
	if (!m)
		return -ENOMEM;

	m->pdev = pdev;
	mutex_init(&m->hw_lock);
	m->active_stream = NULL;
	m->user_irq_mask = 0;
	m->has_per_ch_regs = false;
	m->ch_stride = 0;
	m->ch_count = 0;
	pci_set_drvdata(pdev, m);

	m->xdev = xdma_device_open(DRV_NAME, pdev, &user_max, &h2c_max, &c2h_max);
	if (!m->xdev) {
		dev_err(&pdev->dev, "xdma_device_open failed\n");
		ret = -ENODEV;
		goto err_out;
	}

	/* XDMA user_bar_idx 指向“用户 BAR”，这里映射的就是 FPGA 寄存器空间 */
	if (m->xdev->user_bar_idx < 0 || m->xdev->user_bar_idx >= XDMA_BAR_NUM ||
	    !m->xdev->bar[m->xdev->user_bar_idx]) {
		dev_err(&pdev->dev, "invalid XDMA user BAR idx=%d\n", m->xdev->user_bar_idx);
		ret = -ENODEV;
		goto err_xdma;
	}
	m->user_regs = m->xdev->bar[m->xdev->user_bar_idx];
	/* 尝试检测 per-channel 寄存器窗口（失败也没关系，走 legacy 全局寄存器） */
	(void)video_cap_detect_per_channel_regs(m);

	if (c2h_max <= 0) {
		dev_err(&pdev->dev, "no C2H channels reported by XDMA (c2h_max=%d)\n", c2h_max);
		ret = -ENODEV;
		goto err_xdma;
	}

	/* want：用户希望暴露多少路 /dev/videoX。0 表示“按 XDMA 实际枚举到的通道数自动” */
	want = num_channels ? num_channels : (unsigned int)c2h_max;
	if (c2h_channel >= (unsigned int)c2h_max) {
		dev_err(&pdev->dev, "invalid c2h_channel base=%u (c2h_max=%d)\n", c2h_channel,
			c2h_max);
		ret = -EINVAL;
		goto err_xdma;
	}

	/* Clamp requested channels to what XDMA reports (degrade gracefully). */
	/* 中文说明：即使用户写 num_channels=2，但硬件/枚举只有 1 路，也不会 probe 失败，而是降级创建 1 个 /dev/video0 */
	if (c2h_channel + want > (unsigned int)c2h_max) {
		unsigned int avail = (unsigned int)c2h_max - c2h_channel;

		dev_warn(&pdev->dev, "clamp num_channels=%u to %u (c2h_channel=%u c2h_max=%d)\n",
			 want, avail, c2h_channel, c2h_max);
		want = avail;
	}
	if (want == 0) {
		dev_err(&pdev->dev, "no usable C2H channels (c2h_channel=%u c2h_max=%d)\n",
			c2h_channel, c2h_max);
		ret = -ENODEV;
		goto err_xdma;
	}
	if (irq_index + want > (unsigned int)user_max || irq_index + want > XDMA_USER_IRQ_MAX) {
		/* user_max 是 XDMA 实际可用的 user IRQ 数量（可能 < 16），需要同时满足两边上限 */
		unsigned int avail_user =
			(irq_index < (unsigned int)user_max) ? ((unsigned int)user_max - irq_index) :
							       0;
		unsigned int avail_max =
			(irq_index < XDMA_USER_IRQ_MAX) ? (XDMA_USER_IRQ_MAX - irq_index) : 0;
		unsigned int avail = min(avail_user, avail_max);

		if (avail == 0) {
			dev_err(&pdev->dev, "invalid irq_index base=%u (user_max=%d max=%u)\n",
				irq_index, user_max, XDMA_USER_IRQ_MAX);
			ret = -EINVAL;
			goto err_xdma;
		}

		dev_warn(&pdev->dev,
			 "clamp num_channels=%u to %u due to user IRQ limits (irq_index=%u user_max=%d max=%u)\n",
			 want, avail, irq_index, user_max, XDMA_USER_IRQ_MAX);
		want = min(want, avail);
	}

	m->num_devs = want;
	m->devs = kcalloc(want, sizeof(*m->devs), GFP_KERNEL);
	if (!m->devs) {
		ret = -ENOMEM;
		goto err_xdma;
	}

	ret = v4l2_device_register(&pdev->dev, &m->v4l2_dev);
	if (ret) {
		dev_err(&pdev->dev, "v4l2_device_register failed: %d\n", ret);
		goto err_devs;
	}
	v4l2_registered = true;

	for (i = 0; i < want; i++) {
		u32 bit;

		dev = kzalloc(sizeof(*dev), GFP_KERNEL);
		if (!dev) {
			ret = -ENOMEM;
			goto err_loop;
		}

		dev->multi = m;
		dev->pdev = pdev;
		dev->xdev = m->xdev;
		dev->user_regs = m->user_regs;

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
		dev->c2h_channel = c2h_channel + i;
		dev->irq_index = irq_index + i;

		/*
		 * user_irq_mask 用于 enable/disable/注销 handler：
		 * - 1 bit 对应一条 VSYNC 中断线
		 * - 这里每个 /dev/videoX 绑定一条中断线
		 */
		bit = (u32)BIT(dev->irq_index);
		dev->user_irq_mask = bit;
		m->user_irq_mask |= bit;

		/* 注册 VSYNC 中断回调（注意：真正 enable 发生在 STREAMON） */
		ret = xdma_user_isr_register(m->xdev, bit, video_cap_user_irq_handler, dev);
		if (ret) {
			dev_err(&pdev->dev, "register user irq handler failed (irq=%u): %d\n",
				dev->irq_index, ret);
			goto err_loop;
		}

		ret = video_cap_register_v4l2(dev);
		if (ret)
			goto err_loop;

		m->devs[i] = dev;

		dev_info(&pdev->dev, DRV_NAME ": registered /dev/video%d (pci=%s c2h=%u irq=%u)\n",
			 dev->vdev.num, pci_name(pdev), dev->c2h_channel, dev->irq_index);
		video_cap_stats_dump(dev, "probe");
		dev = NULL;
	}

	return 0;

err_loop:
	if (dev) {
		xdma_user_isr_register(m->xdev, (u32)BIT(dev->irq_index), NULL, NULL);
		kfree(dev);
		dev = NULL;
	}
	while (i > 0) {
		struct video_cap_dev *d;

		i--;
		d = m->devs[i];

		if (!d)
			continue;
		if (d->streaming)
			video_cap_stop_streaming(&d->vb_queue);
		video_cap_unregister_v4l2(d);
		xdma_user_isr_register(m->xdev, d->user_irq_mask, NULL, NULL);
		kfree(d);
		m->devs[i] = NULL;
	}
	if (v4l2_registered)
		v4l2_device_unregister(&m->v4l2_dev);
err_devs:
	kfree(m->devs);
	m->devs = NULL;
err_xdma:
	if (m->xdev) {
		xdma_user_isr_disable(m->xdev, m->user_irq_mask);
		xdma_user_isr_register(m->xdev, m->user_irq_mask, NULL, NULL);
		xdma_device_close(pdev, m->xdev);
		m->xdev = NULL;
	}
err_out:
	pci_set_drvdata(pdev, NULL);
	kfree(m);
	return ret;
}

/*
 * PCI remove：
 * - 逐个停止 streaming（若正在采集）
 * - 注销 /dev/videoX
 * - 注销 user IRQ handler 并关闭 XDMA
 */
static void video_cap_pci_remove(struct pci_dev *pdev)
{
	struct video_cap_multi *m = pci_get_drvdata(pdev);
	unsigned int i;

	if (!m)
		return;

	for (i = 0; i < m->num_devs; i++) {
		struct video_cap_dev *dev = m->devs ? m->devs[i] : NULL;

		if (!dev)
			continue;
		if (dev->streaming)
			video_cap_stop_streaming(&dev->vb_queue);
		video_cap_unregister_v4l2(dev);
		if (m->xdev)
			xdma_user_isr_register(m->xdev, dev->user_irq_mask, NULL, NULL);
		video_cap_stats_dump(dev, "remove");
		kfree(dev);
	}

	if (m->xdev) {
		xdma_user_isr_disable(m->xdev, m->user_irq_mask);
		xdma_user_isr_register(m->xdev, m->user_irq_mask, NULL, NULL);
		xdma_device_close(pdev, m->xdev);
		m->xdev = NULL;
	}

	v4l2_device_unregister(&m->v4l2_dev);
	kfree(m->devs);
	pci_set_drvdata(pdev, NULL);
	kfree(m);
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
