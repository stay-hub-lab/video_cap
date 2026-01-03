# kmod：video_cap_pcie_v4l2（方案B）

本目录输出一个单一内核模块：`video_cap_pcie_v4l2.ko`。

- PCIe 侧：在本模块内直接使用（集成的）XDMA core（`xdma_device_open/xdma_xfer_submit/xdma_user_isr_*`）
- V4L2 侧：注册 `/dev/videoX`，用 `vb2-dma-sg` 管理 buffer，并把 `sg_table` 直接交给 `xdma_xfer_submit()` 做 C2H DMA

## 构建

在 Linux 机器上：

```bash
cd deploy/planB_monolithic/kmod
make
```

## 加载与使用

如果你用 `insmod` 直接加载，先手工加载 V4L2/vb2 依赖模块（否则可能出现 `Unknown symbol in module`）：

```bash
sudo modprobe -a videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg || true
```

最常用的加载方式（指定 C2H 通道与 VSYNC IRQ）：

```bash
sudo insmod video_cap_pcie_v4l2.ko c2h_channel=0 irq_index=1
```

确认设备与播放：

```bash
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --all
ffplay -f v4l2 -video_size 1920x1080 -input_format bgr0 -i /dev/video0
```

切换到 YUYV（YUV422）：

```bash
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=YUYV
ffplay -f v4l2 -video_size 1920x1080 -input_format yuyv422 -i /dev/video0
```

## 参数说明

### insmod 参数（module_param）

- `c2h_channel`：C2H 通道号（默认 0）
- `irq_index`：用作 VSYNC 的 XDMA user IRQ 编号（默认 1）
- `test_pattern`：是否让 FPGA 输出测试图（默认 1）
- `skip`：STREAMON 后丢弃 N 帧（warm-up，默认 0）
- `vsync_timeout_ms`：等待 VSYNC 的超时时间（ms，默认 1000）

说明：`test_pattern/skip/vsync_timeout_ms` 也可以在加载后用 V4L2 controls 设置（见下文）。

## 调试与运行时控制

调试信息：
- `dmesg` 中会在 `probe/streamoff/remove` 打印统计信息（VSYNC 次数、超时次数、DMA 次数/错误次数），用于快速判断“是否在来 VSYNC、DMA 是否正常”。
- 如果出现 `vsync timeout`，优先检查 FPGA 是否真的输出了对应 user IRQ（以及 `irq_index` 是否匹配），并适当调大 VSYNC 超时。

运行时参数（V4L2 controls）：

### YUYV / “buffer corrupted” 排查
- 如果 `ffplay/ffmpeg` 提示 `Dequeued v4l2 buffer contains corrupted data`，同时 `dmesg` 出现 `xdma_xfer_submit ... timed out` / `dma_short`，大多是 vb2-dma-sg 的 buffer 按 PAGE_SIZE 向上取整，导致 `sg_table` 总 DMA 长度 > `sizeimage`。
- 解决办法：驱动侧把提交给 XDMA 的 DMA 长度裁剪到精确的 `sizeimage`（否则 XDMA 会等待 padding 区而超时）。
- 先查看支持的控件：`v4l2-ctl -d /dev/video0 --list-ctrls`
- 设置测试图：`v4l2-ctl -d /dev/video0 --set-ctrl=video_cap_test_pattern=1`
- 设置 warm-up 丢帧数：`v4l2-ctl -d /dev/video0 --set-ctrl=video_cap_skip=2`
- 设置 VSYNC 等待超时（低延时场景建议 30~200ms）：`v4l2-ctl -d /dev/video0 --set-ctrl=video_cap_vsync_timeout_ms=100`
- 读取运行统计（只读）：`v4l2-ctl -d /dev/video0 --get-ctrl=video_cap_vsync_timeout`、`v4l2-ctl -d /dev/video0 --get-ctrl=video_cap_dma_error`

注意：为简化状态机，streaming 期间修改这些 controls 会返回 busy。

## 卸载

```bash
sudo rmmod video_cap_pcie_v4l2
```

## 重要说明

- `kmod/xdma/` 已包含完整 XDMA 源码拷贝（把整个 `deploy/planB_monolithic/` 拷贝到 Linux 即可独立编译）。
- 这不是把“官方 xdma.ko”当依赖，而是把其核心代码直接编译进本模块中；因此不需要先加载 `xdma.ko`。
