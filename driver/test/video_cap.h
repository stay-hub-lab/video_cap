/*
 * video_cap.h - PCIe视频采集驱动头文件
 *
 * Copyright (C) 2024
 */

#ifndef __VIDEO_CAP_H__
#define __VIDEO_CAP_H__

#ifdef __KERNEL__
#include <linux/ioctl.h>
#include <linux/types.h>
#else
/* 用户空间 */
#include <stdint.h>
#include <sys/ioctl.h>

typedef uint8_t __u8;
typedef uint16_t __u16;
typedef uint32_t __u32;
typedef uint64_t __u64;
#endif

/*
 * 驱动信息
 */
#define DRIVER_NAME "video_cap"
#define DRIVER_VERSION "1.0.0"
#define DRIVER_DESC "PCIe Video Capture Card Driver"

/*
 * 设备限制
 */
#define MAX_DEVICES 4
#define MAX_DMA_CHANNELS 4
#define MAX_USER_IRQ 4

/*
 * DMA缓冲区配置
 */
#define DMA_BUFFER_COUNT 4                /* DMA缓冲区数量 (双缓冲/三缓冲) */
#define DMA_BUFFER_SIZE (8 * 1024 * 1024) /* 每个缓冲区8MB (> 1080p RGB帧) */
#define DMA_ALIGNMENT 4096                /* 页面对齐 */

/*
 * IOCTL 接口定义
 */
#define VIDEO_CAP_MAGIC 'V'

/* 获取驱动版本 */
#define VIDEO_CAP_GET_VERSION                                                  \
  _IOR(VIDEO_CAP_MAGIC, 0x01, struct video_cap_version)

/* 获取设备信息 */
#define VIDEO_CAP_GET_INFO _IOR(VIDEO_CAP_MAGIC, 0x02, struct video_cap_info)

/* 读寄存器 */
#define VIDEO_CAP_READ_REG _IOWR(VIDEO_CAP_MAGIC, 0x10, struct video_cap_reg)

/* 写寄存器 */
#define VIDEO_CAP_WRITE_REG _IOW(VIDEO_CAP_MAGIC, 0x11, struct video_cap_reg)

/* 开始采集 */
#define VIDEO_CAP_START _IO(VIDEO_CAP_MAGIC, 0x20)

/* 停止采集 */
#define VIDEO_CAP_STOP _IO(VIDEO_CAP_MAGIC, 0x21)

/* 获取帧 (阻塞) */
#define VIDEO_CAP_GET_FRAME _IOR(VIDEO_CAP_MAGIC, 0x22, struct video_cap_frame)

/* 设置视频格式 */
#define VIDEO_CAP_SET_FORMAT                                                   \
  _IOW(VIDEO_CAP_MAGIC, 0x30, struct video_cap_format)

/* 获取视频格式 */
#define VIDEO_CAP_GET_FORMAT                                                   \
  _IOR(VIDEO_CAP_MAGIC, 0x31, struct video_cap_format)

/* 获取统计信息 */
#define VIDEO_CAP_GET_STATS _IOR(VIDEO_CAP_MAGIC, 0x40, struct video_cap_stats)

/* 复位设备 */
#define VIDEO_CAP_RESET _IO(VIDEO_CAP_MAGIC, 0x50)

/*
 * IOCTL 数据结构
 */

struct video_cap_version {
  __u32 major;
  __u32 minor;
  __u32 patch;
  __u32 fpga_version;
  char build_date[16];
  char build_time[16];
};

struct video_cap_info {
  __u32 vendor_id;
  __u32 device_id;
  __u32 subsystem_id;
  __u32 pcie_link_speed; /* GT/s x 10 */
  __u32 pcie_link_width;
  __u32 bar0_size;
  __u32 dma_buffer_size;
  __u32 dma_buffer_count;
  __u32 max_width;
  __u32 max_height;
  __u32 capabilities;
};

struct video_cap_reg {
  __u32 offset;
  __u32 value;
};

struct video_cap_format {
  __u32 width;
  __u32 height;
  __u32 pixel_format; /* V4L2 fourcc */
  __u32 bytes_per_line;
  __u32 frame_size;
  __u32 frame_rate; /* fps x 100 */
};

struct video_cap_frame {
  __u64 timestamp; /* 纳秒 */
  __u32 sequence;  /* 帧序号 */
  __u32 size;      /* 实际数据大小 */
  __u32 flags;     /* 帧标志 */
  __u32 reserved;
};

struct video_cap_stats {
  __u64 frames_captured;
  __u64 frames_dropped;
  __u64 bytes_transferred;
  __u64 dma_errors;
  __u64 overflow_count;
  __u64 underflow_count;
  __u32 current_fps; /* fps x 100 */
  __u32 uptime_seconds;
};

/*
 * 帧标志
 */
#define FRAME_FLAG_KEYFRAME (1 << 0)
#define FRAME_FLAG_ERROR (1 << 1)
#define FRAME_FLAG_LAST (1 << 2)
#define FRAME_FLAG_TIMESTAMP (1 << 3)

/*
 * 能力标志 (video_cap_info.capabilities)
 */
#define CAP_VIDEO_CAPTURE (1 << 0)
#define CAP_STREAMING (1 << 1)
#define CAP_READ_WRITE (1 << 2)
#define CAP_ASYNC_IO (1 << 3)

#endif /* __VIDEO_CAP_H__ */
