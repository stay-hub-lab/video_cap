# kmod：video_cap_pcie_v4l2（方案B）
本目录输出单一内核模块：`video_cap_pcie_v4l2.ko`

- PCIe 侧：模块内集成 XDMA（`xdma_device_open/xdma_xfer_submit/xdma_user_isr_*`）
- V4L2 侧：注册 `/dev/videoX`，使用 `vb2-dma-sg` 管理 buffer，并把 `sg_table` 直接提交给 XDMA C2H DMA

## 源码模块分层（方便维护）
驱动源码已从单文件拆分为多文件（功能不变，便于后续做多通道/低延时优化）：

- `video_cap_pcie_v4l2_drv.c`：PCI probe/remove + module_param + 创建 `/dev/videoX`
- `video_cap_pcie_v4l2_hw.c`：FPGA user BAR 寄存器访问（CTRL/VID_FORMAT/CAPS）+ 统计打印
- `video_cap_pcie_v4l2_vb2.c`：vb2 ops + 采集线程 + VSYNC wait + XDMA DMA submit
- `video_cap_pcie_v4l2_v4l2.c`：V4L2 ioctl/controls + vb2_queue/video_device 注册
- `video_cap_pcie_v4l2_priv.h`：共用结构体/内部接口

## 构建
在 Linux 机器上：

```bash
cd driver/v4l2/kmod
make
```

## 加载与使用
如果用 `insmod` 直接加载，建议先加载 V4L2/vb2 依赖模块（否则可能 `Unknown symbol in module`）：

```bash
sudo modprobe -a videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg || true
```

单通道（最常用）：

```bash
sudo insmod video_cap_pcie_v4l2.ko c2h_channel=0 irq_index=1
```

多通道（需要 XDMA 实际枚举到多路 C2H）：

```bash
sudo insmod video_cap_pcie_v4l2.ko num_channels=2 c2h_channel=0 irq_index=1
```

确认设备节点：

```bash
v4l2-ctl --list-devices
ls -l /dev/video*
v4l2-ctl -d /dev/video0 --list-formats-ext
```

## 播放/抓帧（XR24 / YUYV）
提示：像素格式是“每路 `/dev/videoX` 独立设置”的，下面用 `/dev/video0` 举例；第二路就把命令里的 `video0` 改成 `video1`。

### XR24（32-bit BGRX；`ffplay` 用 `bgr0`）

```bash
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=XR24
ffplay -f v4l2 -video_size 1920x1080 -input_format bgr0 -i /dev/video0
```

### YUYV（YUV422；`ffplay` 用 `yuyv422`）

```bash
v4l2-ctl -d /dev/video1 --set-fmt-video=width=1920,height=1080,pixelformat=YUYV
ffplay -f v4l2 -video_size 1920x1080 -input_format yuyv422 -i /dev/video1
```

## 多通道（裸机/FPGA/BD）接线约定
驱动按“通道 i”使用：

- C2H engine：`c2h_channel + i`
- VSYNC user IRQ bit：`irq_index + i`

建议约定：

- `irq_index=1`：ch0 用 `usr_irq_req[1]`，ch1 用 `usr_irq_req[2]`
- 每个 `video_cap_c2h_bridge` 实例只拉高一个 VSYNC bit（`VSYNC_IRQ_BIT`），其余 bit 保持 0，避免未 ACK 导致 pending

BD 里常见做法：

- 两个 `video_cap_c2h_bridge`：`VSYNC_IRQ_BIT` 分别设为 `1/2`
- 两路 bridge 的 `usr_irq_req[VSYNC_IRQ_BIT]` 通过 `xlconcat` 接到 XDMA `usr_irq_req[3:0]`（ACK 反向用 `xlslice` 分给两路）

寄存器（多通道窗口/stride 等）参考：`fpga/REGMAP_multichannel.md`

## 参数说明（insmod module_param）
- `c2h_channel`：第一路 C2H 通道号（base，默认 0）
- `irq_index`：第一路用作 VSYNC 的 XDMA user IRQ 编号（base，默认 1）
- `num_channels`：暴露多少路 `/dev/videoX`（0=自动按 XDMA 枚举到的 C2H 通道数）
- `test_pattern`：是否让 FPGA 输出测试图（默认 1）
- `skip`：STREAMON 后丢弃 N 帧（warm-up，默认 0）
- `vsync_timeout_ms`：等待 VSYNC 超时（ms，默认 1000）

说明：

- 多通道时每路 video 使用 `c2h_channel + i` 和 `irq_index + i`（`i` 从 0 开始）
- 若 `num_channels` 大于 XDMA 实际枚举到的 C2H 数，驱动会打印 `clamp num_channels=...` 并按可用通道数降级创建 `/dev/videoX`
- 当前驱动实现有一个限制：在 FPGA 不支持 per-channel CTRL/VID_FORMAT 之前，同一时刻只允许一路 `/dev/videoX` 进入 streaming（其余返回 `EBUSY`）；后续要做“多路同时采集”需要完全 per-channel 化（寄存器/IRQ/DMA 资源隔离）

## 调试与排查

```bash
sudo dmesg -T | tail -n 120
v4l2-ctl -d /dev/video0 --all
```

### “buffer corrupted” / DMA timeout
如果 `ffplay/ffmpeg` 提示 `Dequeued v4l2 buffer contains corrupted data`，同时 `dmesg` 出现 `xdma_xfer_submit ... timed out`，一般优先检查：

- FPGA 的 VSYNC IRQ 是否映射到了正确的 `irq_index + i`
- FPGA 输出字节流是否与当前 pixelformat 一致（`XR24` 对应 `bgr0`；`YUYV` 对应 `yuyv422`）

## 卸载

```bash
sudo rmmod video_cap_pcie_v4l2
```

## 重要说明

- 本工程的 `driver/v4l2/kmod/xdma/` 已包含 XDMA 核心源码并集成编译进 `video_cap_pcie_v4l2.ko`，不需要额外加载“官方 xdma.ko”
- 同一块 PCIe 设备不要同时加载两套驱动（会抢占同一个 PCI device）
