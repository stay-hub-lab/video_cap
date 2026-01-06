// SPDX-License-Identifier: GPL-2.0

/*
 * video_cap_pcie_v4l2_hw.c
 *
 * 这一文件只放“跟 FPGA user BAR 寄存器交互/统计打印”相关的代码：
 * - 读取 REG_CAPS，判断是否支持 per-channel 寄存器窗口
 * - 计算每个通道的寄存器偏移（stride）
 * - 写入 CTRL/VID_FORMAT，控制 FPGA 采集与像素格式
 */

#include <linux/io.h>

#include "video_cap_regs.h"

#include "video_cap_pcie_v4l2_priv.h"

/* 读取 FPGA user BAR 寄存器（32-bit） */
u32 video_cap_reg_read32(struct video_cap_dev *dev, u32 off)
{
	return ioread32((u8 __iomem *)dev->user_regs + off);
}

/* 写 FPGA user BAR 寄存器（32-bit） */
void video_cap_reg_write32(struct video_cap_dev *dev, u32 off, u32 val)
{
	iowrite32(val, (u8 __iomem *)dev->user_regs + off);
}

/*
 * 检测 FPGA 是否支持 per-channel 寄存器窗口。
 * - 成功：m->has_per_ch_regs=true，并填充 ch_count/ch_stride
 * - 失败：保持 legacy 全局寄存器访问方式
 */
/* 函数：检测 per-channel 寄存器窗口能力（REG_CAPS） */
bool video_cap_detect_per_channel_regs(struct video_cap_multi *m)
{
	u32 caps;
	u32 ch_cnt;
	u32 stride;
	u32 feats;

	if (!m->user_regs)
		return false;

	/*
	 * REG_CAPS 由 FPGA register_bank 提供：
	 * - feature bit：是否支持 per-channel CTRL/VID_FORMAT
	 * - ch_cnt：硬件通道数
	 * - stride：每通道寄存器窗口跨度
	 */
	caps = ioread32((u8 __iomem *)m->user_regs + REG_CAPS);
	feats = caps & (CAPS_FEAT_PER_CH_CTRL | CAPS_FEAT_PER_CH_FMT);
	ch_cnt = (caps & CAPS_CH_COUNT_MASK) >> CAPS_CH_COUNT_SHIFT;
	stride = (caps & CAPS_CH_STRIDE_MASK) >> CAPS_CH_STRIDE_SHIFT;

	/*
	 * 合法性要求：
	 * - 至少支持 per-channel CTRL/VID_FORMAT
	 * - channel 数 >= 1
	 * - stride >= 0x20，且 4 字节对齐
	 */
	if (feats != (CAPS_FEAT_PER_CH_CTRL | CAPS_FEAT_PER_CH_FMT))
		return false;
	if (ch_cnt == 0)
		return false;
	if (stride < 0x20 || (stride & 0x3))
		return false;

	m->has_per_ch_regs = true;
	m->ch_count = ch_cnt;
	m->ch_stride = stride;
	return true;
}

/*
 * 计算某个通道的寄存器地址偏移：
 * - REG_CH_BASE + (c2h_channel * stride) + ch_off
 * 注意：这里用 c2h_channel 作为“逻辑通道号”，要求 FPGA 侧通道窗口编号与其一致。
 */
/* 函数：计算 per-channel 寄存器偏移（REG_CH_BASE + ch*stride + off） */
u32 video_cap_ch_reg_off(struct video_cap_dev *dev, u32 ch_off)
{
	u32 stride = dev->multi && dev->multi->ch_stride ? dev->multi->ch_stride : 0x100;

	/* per-channel 窗口：REG_CH_BASE + ch*stride + 具体寄存器偏移 */
	return REG_CH_BASE + (dev->c2h_channel * stride) + ch_off;
}

/* 将 V4L2 pixelformat 映射到 FPGA 寄存器里的视频格式枚举（VID_FMT_*） */
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

/*
 * 把当前 dev->pixfmt 同步到 FPGA：
 * - per-channel：写 REG_CH_OFF_VID_FORMAT
 * - legacy：写 REG_VID_FORMAT
 */
void video_cap_apply_hw_format(struct video_cap_dev *dev)
{
	u32 fmt;
	u32 off;

	if (!dev->user_regs)
		return;

	fmt = video_cap_pixfmt_to_fpga_vid_fmt(dev->pixfmt);
	/* 有 per-channel regs 就写通道窗口；否则写 legacy 全局寄存器 */
	if (dev->multi && dev->multi->has_per_ch_regs)
		off = video_cap_ch_reg_off(dev, REG_CH_OFF_VID_FORMAT);
	else
		off = REG_VID_FORMAT;
	video_cap_reg_write32(dev, off, fmt);
}

/*
 * 使能/关闭 FPGA 采集：
 * - enable=true：写 CTRL_ENABLE，可选写 CTRL_TEST_MODE
 * - enable=false：写 0（关闭采集）
 *
 * 注意：enable 之前会先同步 VID_FORMAT，避免用户态未显式 S_FMT 的情况。
 */
/* 函数：使能/关闭采集（写 CONTROL 寄存器） */
int video_cap_enable(struct video_cap_dev *dev, bool enable)
{
	u32 ctrl = 0;
	u32 off;

	if (!dev->user_regs)
		return -ENODEV;

	if (enable) {
		/* enable 前把像素打包格式同步给 FPGA（避免用户空间未显式 S_FMT 的情况） */
		video_cap_apply_hw_format(dev);
		ctrl |= CTRL_ENABLE;
		if (dev->test_pattern)
			ctrl |= CTRL_TEST_MODE;
	}

	/* 同上：优先写 per-channel，否则写 legacy 全局 */
	if (dev->multi && dev->multi->has_per_ch_regs)
		off = video_cap_ch_reg_off(dev, REG_CH_OFF_CONTROL);
	else
		off = REG_CONTROL;
	video_cap_reg_write32(dev, off, ctrl);
	return 0;
}

/* 初始化统计计数器（用于 dmesg 打印 / V4L2 volatile ctrl） */
void video_cap_stats_init(struct video_cap_dev *dev)
{
	atomic64_set(&dev->stats.vsync_isr, 0);
	atomic64_set(&dev->stats.vsync_wait, 0);
	atomic64_set(&dev->stats.vsync_timeout, 0);
	atomic64_set(&dev->stats.dma_submit, 0);
	atomic64_set(&dev->stats.dma_error, 0);
	atomic64_set(&dev->stats.dma_short, 0);
	atomic64_set(&dev->stats.dma_trim, 0);
}

/* 打印当前统计计数器（用于 probe/streamoff/remove 观察运行情况） */
void video_cap_stats_dump(struct video_cap_dev *dev, const char *tag)
{
	dev_info(&dev->pdev->dev,
		 "%s: vsync_isr=%lld vsync_wait=%lld vsync_timeout=%lld dma_submit=%lld dma_error=%lld dma_short=%lld dma_trim=%lld\n",
		 tag, (long long)atomic64_read(&dev->stats.vsync_isr),
		 (long long)atomic64_read(&dev->stats.vsync_wait),
		 (long long)atomic64_read(&dev->stats.vsync_timeout),
		 (long long)atomic64_read(&dev->stats.dma_submit),
		 (long long)atomic64_read(&dev->stats.dma_error),
		 (long long)atomic64_read(&dev->stats.dma_short),
		 (long long)atomic64_read(&dev->stats.dma_trim));
}
