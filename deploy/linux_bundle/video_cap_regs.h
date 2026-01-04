/*
 * video_cap_regs.h - PCIe视频采集卡寄存器定义
 *
 * 该文件定义了与FPGA register_bank模块匹配的寄存器映射。
 * 所有寄存器均为32位对齐。
 *
 * Copyright (C) 2024
 */

#ifndef __VIDEO_CAP_REGS_H__
#define __VIDEO_CAP_REGS_H__

/*
 * 基地址区域 (BAR0)
 */
#define BAR0_USER_REGS_OFFSET 0x00000000
#define BAR0_USER_REGS_SIZE 0x00001000 /* 4KB */

/*
 * 寄存器偏移 (相对于BAR0)
 * 必须与 FPGA register_bank.v 中的定义一致!
 */

/* 核心寄存器 (与register_bank.v完全对应) */
#define REG_VERSION 0x0000    /* RO: 版本寄存器 (ADDR_VERSION) */
#define REG_CONTROL 0x0004    /* RW: 控制寄存器 (ADDR_CONTROL) */
#define REG_STATUS 0x0008     /* RO: 状态寄存器 (ADDR_STATUS) */
#define REG_IRQ_MASK 0x000C   /* RW: 中断屏蔽 (ADDR_IRQ_MASK) */
#define REG_IRQ_STATUS 0x0010 /* RW1C: 中断状态 (ADDR_IRQ_STATUS) */
#define REG_CAPS 0x0014       /* RO: 能力/参数描述（多通道扩展） */

/* 视频配置 */
#define REG_VID_FORMAT 0x0100     /* RW: 视频格式 (ADDR_VID_FMT) */
#define REG_VID_RESOLUTION 0x0104 /* RO: 分辨率 (ADDR_VID_RES) */

/* 帧缓存地址 */
#define REG_BUF_ADDR0 0x0200 /* RW: 帧缓存地址0 */
#define REG_BUF_ADDR1 0x0204 /* RW: 帧缓存地址1 */
#define REG_BUF_ADDR2 0x0208 /* RW: 帧缓存地址2 */
#define REG_BUF_IDX 0x0210   /* RO: 当前缓存索引 */

/* 调试计数器 (未在当前FPGA中实现) */
#define REG_DBG_PIXEL_COUNT 0x0300 /* RO: 像素计数 */
#define REG_DBG_LINE_COUNT 0x0304  /* RO: 行计数 */
#define REG_DBG_FRAME_COUNT 0x0308 /* RO: 帧计数 */
#define REG_DBG_ERROR_COUNT 0x030C /* RO: 错误计数 */

/*
 * REG_VERSION 位定义
 */
#define VERSION_MAJOR_MASK 0xFF000000
#define VERSION_MAJOR_SHIFT 24
#define VERSION_MINOR_MASK 0x00FF0000
#define VERSION_MINOR_SHIFT 16
#define VERSION_PATCH_MASK 0x0000FFFF
#define VERSION_PATCH_SHIFT 0

/*
 * REG_CONTROL 位定义
 */
#define CTRL_ENABLE (1 << 0)     /* 全局使能 */
#define CTRL_SOFT_RESET (1 << 1) /* 软复位 (自动清除) */
#define CTRL_TEST_MODE (1 << 2)  /* 测试图案模式 */
#define CTRL_LOOPBACK (1 << 3)   /* 回环模式 */

/*
 * REG_STATUS 位定义
 */
#define STS_IDLE (1 << 0)          /* 系统空闲 */
#define STS_MIG_CALIB (1 << 1)     /* MIG校准完成 */
#define STS_FIFO_OVERFLOW (1 << 2) /* FIFO溢出 */
#define STS_PCIE_LINK_UP (1 << 3)  /* PCIe链路已建立 */
#define STS_VIDEO_ACTIVE (1 << 4)  /* 视频活动中 */
#define STS_DMA_BUSY (1 << 5)      /* DMA传输中 */

/*
 * REG_IRQ_MASK / REG_IRQ_STATUS 位定义
 */
#define IRQ_FRAME_DONE (1 << 0) /* 帧完成 */
#define IRQ_DMA_ERROR (1 << 1)  /* DMA错误 */
#define IRQ_OVERFLOW (1 << 2)   /* 缓冲区溢出 */
#define IRQ_UNDERFLOW (1 << 3)  /* 缓冲区欠流 */

/*
 * REG_CAPS 位定义（建议）
 * - 为了支持多 C2H 通道并发采集，推荐加入 per-channel 控制/格式寄存器。
 *
 * [0]   CAPS_FEAT_PER_CH_CTRL  : 每个 channel 有独立 CTRL_ENABLE/TEST_MODE/SOFT_RESET
 * [1]   CAPS_FEAT_PER_CH_FMT   : 每个 channel 有独立 VID_FORMAT
 * [2]   CAPS_FEAT_PER_CH_STS   : 每个 channel 有独立 STATUS/overflow/underflow
 * [7:4] reserved
 * [15:8] CAPS_CH_COUNT         : 支持的 channel 数（>=1）
 * [31:16] CAPS_CH_STRIDE       : per-channel 寄存器 block stride（bytes，>=0x20）
 */
#define CAPS_FEAT_PER_CH_CTRL (1u << 0)
#define CAPS_FEAT_PER_CH_FMT  (1u << 1)
#define CAPS_FEAT_PER_CH_STS  (1u << 2)
#define CAPS_CH_COUNT_MASK    0x0000FF00u
#define CAPS_CH_COUNT_SHIFT   8
#define CAPS_CH_STRIDE_MASK   0xFFFF0000u
#define CAPS_CH_STRIDE_SHIFT  16

/*
 * 建议的 per-channel 寄存器布局（后续 FPGA register_bank 改造用）
 * - 保持现有单通道寄存器后向兼容（REG_CONTROL/REG_VID_FORMAT 等）
 * - 新增 per-channel block：REG_CH_BASE + ch * stride + OFF_*
 */
#define REG_CH_BASE 0x1000u
#define REG_CH_OFF_CONTROL    0x00u
#define REG_CH_OFF_VID_FORMAT 0x04u
#define REG_CH_OFF_STATUS     0x08u

/*
 * REG_VID_CONTROL 位定义
 */
#define VID_CTRL_START (1 << 0)        /* 开始采集 */
#define VID_CTRL_STOP (1 << 1)         /* 停止采集 */
#define VID_CTRL_SINGLE_FRAME (1 << 2) /* 单帧模式 */
#define VID_CTRL_CONTINUOUS (1 << 3)   /* 连续模式 */

/*
 * REG_VID_FORMAT 位定义
 */
#define VID_FMT_RGB888 0x00 /* RGB 8:8:8 */
#define VID_FMT_YUV422 0x01 /* YUV 4:2:2 */
#define VID_FMT_YUV444 0x02 /* YUV 4:4:4 */
#define VID_FMT_RAW8 0x10   /* RAW 8-bit */
#define VID_FMT_RAW10 0x11  /* RAW 10-bit */
#define VID_FMT_RAW12 0x12  /* RAW 12-bit */

/*
 * REG_DMA_CONTROL 位定义
 */
#define DMA_CTRL_START (1 << 0) /* 启动DMA */
#define DMA_CTRL_STOP (1 << 1)  /* 停止DMA */
#define DMA_CTRL_RESET (1 << 2) /* 复位DMA引擎 */

/*
 * REG_DMA_STATUS 位定义
 */
#define DMA_STS_IDLE (1 << 0)  /* DMA空闲 */
#define DMA_STS_BUSY (1 << 1)  /* DMA忙 */
#define DMA_STS_ERROR (1 << 2) /* DMA错误 */
#define DMA_STS_DONE (1 << 3)  /* DMA完成 */

/*
 * 视频参数
 */
#define VIDEO_WIDTH_1080P 1920
#define VIDEO_HEIGHT_1080P 1080
#define VIDEO_FRAME_RATE_60 60
#define VIDEO_PIXEL_CLOCK_1080P60 148500000 /* 148.5 MHz */

/* 帧大小计算 */
#define VIDEO_BYTES_PER_PIXEL_RGB 3
#define VIDEO_BYTES_PER_PIXEL_YUV 2
#define VIDEO_FRAME_SIZE_RGB                                                   \
  (VIDEO_WIDTH_1080P * VIDEO_HEIGHT_1080P * VIDEO_BYTES_PER_PIXEL_RGB)
#define VIDEO_FRAME_SIZE_YUV                                                   \
  (VIDEO_WIDTH_1080P * VIDEO_HEIGHT_1080P * VIDEO_BYTES_PER_PIXEL_YUV)

/*
 * XDMA 特定定义
 * Device ID 必须与 XDMA IP 配置中的 PF0_DEVICE_ID 一致!
 */
#define XDMA_VENDOR_ID 0x10EE
#define XDMA_DEVICE_ID 0x7018 /* 注意: 需要与XDMA IP配置匹配 */

/* XDMA通道寄存器偏移 (由XDMA IP生成) */
#define XDMA_C2H_CHANNEL_OFFSET 0x00001000
#define XDMA_H2C_CHANNEL_OFFSET 0x00000000
#define XDMA_IRQ_OFFSET 0x00002000

#endif /* __VIDEO_CAP_REGS_H__ */
