# PCIe 视频采集卡：实现说明（已落地）

本文档用于替代原 `doc/implementation_plan.md`（设计计划文档）。当前工程的 FPGA 逻辑与 Linux V4L2 驱动已跑通，本文记录当前实现、使用方式、以及后续多通道并发采集的改造点。

## 1. 已实现功能概览

- **FPGA（数据通路）**：基于 XDMA Stream（AXI4-Stream -> C2H）的采集链路；支持测试图（彩条）输出；支持在 `XR24`（BGRX32）与 `YUYV`（YUV422）之间切换。
- **Linux（V4L2 驱动）**：单一内核模块 `video_cap_pcie_v4l2.ko`；模块内集成 XDMA core（不依赖系统单独加载官方 `xdma.ko`）；注册 `/dev/videoX`，通过 V4L2 + vb2 提供 mmap/streaming 访问。
- **多通道（设备节点）**：驱动可以创建多个 `/dev/videoX`；每路 video 绑定一条 C2H engine + 一个 user IRQ bit（用于 VSYNC/帧事件同步）。

## 2. 代码与文档目录

- `fpga/`：Vivado 工程、BD、HDL、约束与脚本
  - 入口说明：`fpga/README.md`
  - 多通道寄存器建议：`fpga/REGMAP_multichannel.md`
- `driver/v4l2/`：V4L2 驱动（单模块集成 XDMA）
  - 入口说明：`driver/v4l2/README.md`
  - 内核模块源码：`driver/v4l2/kmod/`（已拆分为 `*_drv.c / *_hw.c / *_vb2.c / *_v4l2.c`）

## 3. Linux 使用方式（驱动 + 播放/抓帧）

更详细的参数解释与调试建议请看 `driver/v4l2/kmod/README.md`。

### 3.1 编译

在目标 Linux 机器（安装了对应内核 headers）上：

```bash
cd driver/v4l2/kmod
make
```

### 3.2 加载

单通道示例（ch0 使用 C2H0，VSYNC 用 user IRQ #1）：

```bash
sudo insmod video_cap_pcie_v4l2.ko c2h_channel=0 irq_index=1
```

多通道示例（创建 2 路 `/dev/video0`、`/dev/video1`）：

```bash
sudo insmod video_cap_pcie_v4l2.ko num_channels=2 c2h_channel=0 irq_index=1
```

确认节点：

```bash
v4l2-ctl --list-devices
ls -l /dev/video*
```

### 3.3 播放（ffplay）/ 抓帧（ffmpeg）

提示：像素格式是“每路 `/dev/videoX` 独立设置”的；下面用 `/dev/video0` 举例，第二路就把命令里的 `video0` 改成 `video1`。

`XR24`（BGRX32，ffplay 用 `bgr0`）：

```bash
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=XR24
ffplay -f v4l2 -video_size 1920x1080 -input_format bgr0 -i /dev/video0
```

`YUYV`（YUV422，ffplay 用 `yuyv422`）：

```bash
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=YUYV
ffplay -f v4l2 -video_size 1920x1080 -input_format yuyv422 -i /dev/video0
```

备注：`ffplay` 退出时偶尔出现 “Some buffers are still owned by the caller on close / VIDIOC_QBUF: Bad file descriptor”，通常是用户态异常退出/快速关闭导致的提示，一般不影响再次打开；如遇到设备卡死，先 `rmmod` 再 `insmod` 复位链路。

## 4. 多通道约定（C2H / IRQ 映射）

驱动对“通道 i”的默认约定：

- **C2H engine**：`c2h_channel + i`
- **VSYNC user IRQ bit**：`irq_index + i`

BD/逻辑侧建议：

- 每个 `video_cap_c2h_bridge` 实例只拉高一个 VSYNC bit（例如 `VSYNC_IRQ_BIT` 设成不同的值），其余 bit 常 0，避免未 ACK 的 pending 干扰；
- XDMA 的 “Number of User Interrupts” 至少要 `>= 通道数`。

## 5. 当前限制与后续优化点

- **多路并发采集**：如果 FPGA user BAR 寄存器仍是“全局 CTRL/VID_FORMAT”的写法，多路同时 STREAMON 容易互相覆盖。驱动在兼容模式下会对 STREAMON 做互斥保护（返回 `EBUSY`），以避免两路同时改同一份寄存器。
- **要做到真正多路同时采集**：建议 FPGA 侧实现 per-channel 寄存器块并暴露能力寄存器（例如 `REG_CAPS/CH_STRIDE/CH_COUNT`），驱动即可自动识别并切换为 per-channel 控制模式；寄存器扩展建议见 `fpga/REGMAP_multichannel.md`。

## 6. 文档迁移

- 原 `doc/implementation_plan.md` 已更名为本文件：`doc/implementation.md`。
