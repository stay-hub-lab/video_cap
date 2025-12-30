# linux_bundle (XDMA + V4L2)

这个目录是一个 **可直接拷贝到 Linux** 的自包含打包：

- `include/` + `xdma/`：来自 `dma_ip_drivers-master/XDMA/linux-kernel`，并包含本项目需要的补丁（导出 `xdma_xfer_submit`）。
- `v4l2/`：本项目的 V4L2 采集卡驱动（使用 `vb2-dma-sg` + `xdma_xfer_submit` 做零拷贝）。

如果你后续在 Windows 端更新了源码，可以运行 `deploy/update_linux_bundle.cmd` 重新生成/同步这个目录。

## 使用方式（建议）

把整个 `deploy/linux_bundle/` 目录复制到 Linux（路径随意），然后：

```bash
cd linux_bundle
```

### 1) 编译并加载 XDMA（补丁版本）

如果你系统里已经加载了别的 `xdma.ko`，先卸载它：

```bash
sudo rmmod xdma || true
```

编译：

```bash
cd xdma
make
```

说明：`make` 会在 `xdma/Module.symvers` 里生成导出符号表，后续编译 `v4l2/` 时需要用到它（否则会报 `undefined xdma_xfer_submit`）。

加载（参数按你的系统/板卡需要，下面只是示例）：

```bash
sudo insmod xdma.ko interrupt_mode=1
```

### 2) 编译并加载 V4L2 驱动

加载 vb2 依赖：

```bash
sudo modprobe -a videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg || true
```

编译：

```bash
cd ../v4l2
make
```

加载（示例：选择第 0 个 xdma 绑定的设备，C2H=0，VSYNC IRQ=1）：

```bash
sudo insmod video_cap_v4l2.ko test_pattern=1 c2h_channel=0 irq_index=1 xdma_index=0
```

如果你的板卡 device id 不是 `0x7018`（比如你这里 `lspci` 显示 `Device 7028`），也可以显式指定：

```bash
sudo insmod video_cap_v4l2.ko test_pattern=1 c2h_channel=0 irq_index=1 xdma_vendor=0x10ee xdma_device=0x7028 xdma_index=0
```

## 测试

```bash
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --all
sudo v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=10 --stream-to=out.raw
ffplay -f rawvideo -pixel_format bgr0 -video_size 1920x1080 out.raw
```

### 如果 `v4l2-ctl --stream-mmap` 卡住（out.raw 为 0）

通常表示驱动线程没有拿到 VSYNC(user IRQ) 或者没有真正完成一次 DMA。
建议按下面顺序快速确认：

```bash
# 1) 确认 xdma 没有在 poll_mode（poll_mode=1 时 /proc/interrupts 可能一直是 0）
cat /sys/module/xdma/parameters/poll_mode

# 2) 直接测试 VSYNC user IRQ 是否在来（2 秒内应读到 4 字节；读不到说明 IRQ 没触发/irq_index 不对/FPGA 未产生）
sudo timeout 2 dd if=/dev/xdma0_events_1 bs=4 count=1 status=none | od -An -tx4

# 3) 看 MSI-X 计数是否在增长（至少应有某一行开始增加）
grep xdma /proc/interrupts | head -n 40
```

## 常见问题

- `VIDIOC_STREAMON Permission denied`：请用 `sudo` 运行，或把用户加入 `video` 组：`sudo usermod -aG video $USER`（重新登录生效）。
- `Unknown symbol xdma_xfer_submit`：说明当前加载的 `xdma.ko` 不是本 bundle 里的补丁版本（或没卸载旧的 xdma）。
