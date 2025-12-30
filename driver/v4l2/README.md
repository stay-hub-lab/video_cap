# video_cap_v4l2

这是一个 V4L2 采集卡驱动：把 FPGA→XDMA 的 C2H AXI-Stream 帧流包装成 `/dev/videoX`。

当前实现（Step-3，推荐）：

- `vb2-dma-sg` 分配 V4L2 buffer，并通过 XDMA 的 `xdma_xfer_submit()` 直接 DMA 到 vb2 buffer（零拷贝/低 CPU）。
- 像素格式固定为 `XBGR32`（`v4l2-ctl` 显示 fourcc `'XR24'`，即 32-bit BGRX 8-8-8-8），与 FPGA 实际字节序一致。
- 用 XDMA user IRQ（默认 `irq_index=1`，对应 `/dev/xdma0_events_1` 那一路）做 VSYNC 帧同步。

重要：由于官方 xdma 源码里 **没有导出** `xdma_xfer_submit`，需要对 `xdma.ko` 打一个很小的补丁（本仓库已加 `EXPORT_SYMBOL_GPL(xdma_xfer_submit)`）。

## 构建

在 Linux 端：

```bash
cd driver/v4l2
make
```

## 依赖与加载顺序

1) 编译并加载本仓库的 XDMA 驱动（带 `xdma_xfer_submit` 导出）：

```bash
cd linux/dma_ip_drivers-master/XDMA/linux-kernel/xdma
make
# 然后按你的系统方式加载 xdma.ko（或用 tests/load_driver.sh）
```

说明：`make` 会生成 `Module.symvers`，本目录下的 `driver/v4l2/Makefile` 已通过 `KBUILD_EXTRA_SYMBOLS` 引用它；否则编译 V4L2 会报 `undefined xdma_xfer_submit`。

2) 加载 V4L2/vb2 依赖模块：

```bash
sudo modprobe -a videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg || true
```

3) 加载本驱动（示例：选择第 0 个 xdma 绑定的设备、C2H=0、IRQ=1、测试图开启）：

```bash
sudo insmod video_cap_v4l2.ko test_pattern=1 c2h_channel=0 irq_index=1 xdma_index=0
```

如果你的板卡 device id 不是 `0x7018`（比如 `lspci` 显示 `Device 7028`），也可以显式指定：

```bash
sudo insmod video_cap_v4l2.ko test_pattern=1 c2h_channel=0 irq_index=1 xdma_vendor=0x10ee xdma_device=0x7028 xdma_index=0
```

如果 `insmod` 报 `Unknown symbol xdma_xfer_submit`：说明你加载的 `xdma.ko` 不是这份补丁版本（或没重新编译/没重载）。

## 使用

查看设备：

```bash
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --all
```

采集测试：

```bash
sudo v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=10 --stream-to=out.raw
```

查看输出（原生 32bpp，BGRX）：

```bash
ffplay -f rawvideo -pixel_format bgr0 -video_size 1920x1080 out.raw
```

## 参数

- `xdma_vendor`/`xdma_device`/`xdma_index`：选择要绑定的 XDMA PCI 功能（默认 0x10ee:0x7018，第 0 个）
- `c2h_channel`：C2H 通道号（默认 0）
- `irq_index`：用作 VSYNC 的 user IRQ 编号（默认 1）
- `test_pattern`：1 开启测试图（REG_CONTROL 的 TEST_MODE），0 为外部输入
- `skip`：STREAMON 后丢弃 N 帧（warm-up，仍然会把数据 DMA 读掉以保证帧对齐）

## 卸载

```bash
sudo rmmod video_cap_v4l2
```

如果提示 `in use`：先确认没有进程占用 `/dev/video*`，以及应用侧已 `STREAMOFF`/退出。
