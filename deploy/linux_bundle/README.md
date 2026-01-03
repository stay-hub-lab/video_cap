# linux_bundle (XDMA + V4L2) 工程说明

`deploy/linux_bundle/` 是一个“可直接拷贝到 Linux 机器上编译/加载”的自包含目录，用于把本项目的 FPGA 视频帧（AXI-Stream）通过 XDMA C2H DMA 搬运到主机内存，并以 V4L2 设备节点 `/dev/videoX` 的形式提供给用户态（`v4l2-ctl/ffplay/opencv/gstreamer/...`）。

本说明文档重点解释两件事：
- `v4l2/video_cap_v4l2.c` 如何调用“官方 XDMA 驱动”（本目录的 `xdma/`）完成 DMA 与帧同步。
- 为什么需要对 XDMA 做一个很小的“补丁”（导出 `xdma_xfer_submit`）。

## 目录结构

- `include/libxdma_api.h`：XDMA 的对外 API 头文件（本 bundle 会用到 `xdma_xfer_submit()` 的声明）。
- `xdma/`：Xilinx 官方 XDMA Linux kernel driver 源码（来自 `dma_ip_drivers` 仓库对应目录），并包含本项目需要的补丁：在 `xdma/libxdma.c` 里导出 `xdma_xfer_submit`。
- `v4l2/`：本项目的 V4L2 采集驱动，把 XDMA C2H 流封装成 `/dev/videoX`，并通过 `vb2-dma-sg` 实现零拷贝采集。
- `video_cap.h`、`video_cap_regs.h`：FPGA 用户寄存器/控制位定义（V4L2 驱动会写用户 BAR 来使能采集、选择测试图等）。
- `build_all.sh`：一键编译 `xdma/` 与 `v4l2/`。
- `load_driver.sh`：加载 `xdma.ko` 的辅助脚本（可选）。

## 数据流概览

1. FPGA 产生逐帧视频数据（AXI-Stream），并提供 VSYNC/帧边界信号。
2. XDMA IP 把 AXI-Stream 写入 PCIe（C2H 通道），在主机侧由 `xdma.ko` 完成 DMA。
3. `video_cap_v4l2.ko` 使用 `vb2-dma-sg` 分配/管理 V4L2 buffer，并把 buffer 的 `sg_table` 直接交给 `xdma_xfer_submit()` 进行 DMA 填充。
4. DMA 完成后，V4L2 buffer 出队，用户态通过 `mmap/read` 读到一帧原始图像。

## 编译与加载（推荐流程）

把整个 `deploy/linux_bundle/` 拷贝到 Linux（路径随意），进入目录后执行：

```bash
cd linux_bundle
```

### 0) 环境依赖

- Linux kernel headers：`/lib/modules/$(uname -r)/build` 可用
- 工具链：`make/gcc`
- 用户态工具（可选）：`v4l2-ctl`（v4l-utils）、`ffplay`（ffmpeg）

### 1) 编译并加载 XDMA（补丁版）

如果系统里已经加载过别的 `xdma.ko`，先卸载：

```bash
sudo rmmod xdma || true
```

编译：

```bash
cd xdma
make
cd ..
```

加载（最直接方式）：

```bash
sudo insmod xdma/xdma.ko interrupt_mode=0
```

也可以用脚本（会尝试根据 PCIe 能力选择 MSI/MSI-X/Legacy）：

```bash
sudo ./load_driver.sh 0
```

说明：编译 XDMA 会生成 `xdma/Module.symvers`，后续编译 `v4l2/` 需要它来解析 `xdma_xfer_submit` 符号（见下面“为什么需要补丁”）。

### 2) 编译并加载 V4L2 驱动

先确保 V4L2/vb2 依赖模块可用：

```bash
sudo modprobe -a videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg || true
```

编译：

```bash
cd v4l2
make
cd ..
```

加载（示例：绑定第 0 块 XDMA 设备，使用 C2H 通道 0，使用 user IRQ 1 作为 VSYNC）：

```bash
sudo insmod v4l2/video_cap_v4l2.ko test_pattern=1 c2h_channel=0 irq_index=1 xdma_index=0
```

如果你的设备 ID 不是默认的 `0x7018`（例如 `lspci` 里显示 `7028`），可以显式指定：

```bash
sudo insmod v4l2/video_cap_v4l2.ko test_pattern=1 c2h_channel=0 irq_index=1 xdma_vendor=0x10ee xdma_device=0x7028 xdma_index=0
```

## 使用示例

查看设备：

```bash
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --all
v4l2-ctl -d /dev/video0 --list-formats-ext
```

采集保存 raw：

```bash
sudo v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=10 --stream-to=out.raw
```

播放 raw（本驱动输出 `XBGR32`，ffmpeg/ffplay 通常用 `bgr0` 来表示）：

```bash
ffplay -f rawvideo -pixel_format bgr0 -video_size 1920x1080 out.raw
```

也可以直接播放设备：

```bash
ffplay -f v4l2 -video_size 1920x1080 -input_format bgr0 -i /dev/video0
```

## V4L2 驱动如何调用 XDMA（关键实现点）

本节以 `v4l2/video_cap_v4l2.c` 为主线，说明它与 `xdma/`（官方 XDMA 驱动）之间的“调用/依赖关系”。

### 1) 绑定到已加载的 XDMA 设备（非 probe 模式）

`video_cap_v4l2.ko` **不是**一个 PCI 驱动，它不会在 `probe()` 里枚举硬件；它要求系统里已经加载并绑定了 `xdma.ko`。

绑定流程：
- `video_cap_find_xdma_pdev()`：遍历 PCI 设备，筛选 `pdev->driver->name == "xdma"` 的设备，并按 `xdma_vendor/xdma_device/xdma_index` 选择目标。
- `video_cap_bind_xdma()`：对目标 `pdev` 调用 `dev_get_drvdata(&pdev->dev)` 获取 `struct xdma_pci_dev *`（这是 XDMA 驱动的私有结构），并进一步取得 `xpdev->xdev`（`struct xdma_dev *`）。
  - 通过 `MAGIC_DEVICE` 校验结构体有效性。
  - 校验 `c2h_channel < xdev->c2h_channel_max`、`irq_index < xdev->user_max`。
  - 获取用户逻辑 BAR：`dev->user_regs = xdev->bar[xdev->user_bar_idx]`，用于写 FPGA 用户寄存器（例如 `REG_CONTROL`）。

这意味着：`video_cap_v4l2.c` 依赖 `xdma_mod.h/libxdma.h` 里对 `xdma_pci_dev/xdma_dev` 等内部结构的定义，**与 XDMA 源码版本强绑定**。

### 2) VSYNC/帧同步：复用 XDMA 的 user IRQ 事件队列

`video_cap_wait_vsync()` 会等待 XDMA 的 user IRQ：

- 访问 `user_irq = &dev->xdev->user_irq[dev->irq_index]`
- `wait_event_interruptible_timeout(user_irq->events_wq, user_irq->events_irq != 0, ...)`
- 被唤醒后清零 `events_irq`

对应的 XDMA 侧实现：`xdma/libxdma.c:user_irq_service()` 在收到 user interrupt 时，如果没有注册专用 handler，就会：
- `user_irq->events_irq = 1`
- `wake_up_interruptible(&user_irq->events_wq)`

因此，想让采集“按帧”工作，前提是：
- FPGA 必须把 VSYNC/帧边界映射到 XDMA 的某一路 user IRQ；
- `irq_index` 参数要选对（同时也对应 `/dev/xdma0_events_<irq_index>` 那一路事件设备）。

### 3) DMA 读取一帧：把 vb2 的 sg_table 交给 xdma_xfer_submit()

`video_cap_dma_read_frame()` 里：

- V4L2 buffer 来自 `vb2-dma-sg`（见 `vb_queue.mem_ops = &vb2_dma_sg_memops`）。
- 通过 `vb2_dma_sg_plane_desc(vb, 0)` 取到当前 buffer 的 `struct sg_table *sgt`。
- 直接调用 XDMA：
  - `xdma_xfer_submit(dev->xdev, dev->c2h_channel, false, 0, sgt, true, 1000)`

注意：vb2-dma-sg 的 buffer 往往会按 PAGE_SIZE 向上取整，导致 `sg_table` 的总 DMA 长度可能大于 `sizeimage`。驱动在提交 DMA 时必须把长度裁剪到精确的 `sizeimage`，否则 FPGA 只输出 `sizeimage` 字节时，XDMA 会等待 padding 区导致超时/short frame。

这里的关键点是最后两个参数：
- `dma_mapped=true`：vb2 已经为 `vb_queue.dev = &pdev->dev` 做过 DMA map，因此 XDMA 不需要再次 `dma_map_sg()`。
- `timeout_ms`：XDMA 里目前并不严格使用该超时（以源码实现为准）。

XDMA 侧 `xdma_xfer_submit()`（`xdma/libxdma.c`）会：
- 根据 `write=false` 选择 `engine_c2h[channel]`
- 构造请求/描述符并提交到硬件
- 等待完成（这是一个阻塞调用）
- 返回实际传输字节数

### 4) 采集线程模型（为什么用户态 read/mmap 能拿到帧）

- 用户态 `STREAMON` 后，vb2 会触发 `video_cap_start_streaming()`：
  - 使能 FPGA（写 `REG_CONTROL`）
  - 可选 warm-up：先丢弃 `skip` 帧（仍然做 DMA 读取，只是不交付给用户）
  - 启动内核线程 `video_cap_thread_fn()`
- 线程循环：
  1) 等待有 buffer 入队
  2) 等待 VSYNC（`video_cap_wait_vsync()`）
  3) 提交 DMA 把一帧写入该 buffer（`xdma_xfer_submit()`）
  4) `vb2_buffer_done(..., VB2_BUF_STATE_DONE)` 交给 vb2/V4L2

## 为什么需要对官方 XDMA 打补丁（导出 xdma_xfer_submit）

`v4l2/video_cap_v4l2.c` 直接调用 `xdma_xfer_submit()`。在“官方 XDMA 驱动”原始代码中，这个函数通常是**未导出符号**，外部内核模块无法链接使用。

本 bundle 的 XDMA 已包含补丁：
- 在 `xdma/libxdma.c` 中加入 `EXPORT_SYMBOL_GPL(xdma_xfer_submit);`

并且 V4L2 的 Makefile 明确依赖 XDMA 的 `Module.symvers`：
- `v4l2/Makefile` 里通过 `KBUILD_EXTRA_SYMBOLS += ../xdma/Module.symvers` 让内核构建系统知道 `xdma_xfer_submit` 来自 `xdma.ko`。

结论：**必须先编译（并最好加载）bundle 里的 `xdma/`，再编译 `v4l2/`。**

## 常见问题与排查

- `Unknown symbol xdma_xfer_submit`：正在使用的 `xdma.ko` 不是本 bundle 的补丁版，或 XDMA 没有先编译生成 `Module.symvers`。
- `v4l2-ctl --stream-mmap` 卡住 / `out.raw` 为 0：通常是 VSYNC user IRQ 没有触发或 `irq_index` 不匹配。
  - 看 XDMA 是否在 poll 模式：`cat /sys/module/xdma/parameters/poll_mode`
  - 直接读事件设备验证 IRQ 是否到来（2 秒内应读到 4 字节）：
    ```bash
    sudo timeout 2 dd if=/dev/xdma0_events_1 bs=4 count=1 status=none | od -An -tx4
    ```
  - 看 `/proc/interrupts` 里 XDMA MSI/MSI-X 计数是否增长：`grep xdma /proc/interrupts | head -n 40`
- `VIDIOC_STREAMON Permission denied`：用 `sudo`，或把用户加入 `video` 组：`sudo usermod -aG video $USER`（重新登录生效）。
