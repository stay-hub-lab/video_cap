# 方案B任务计划（单模块：内置 XDMA core + V4L2）

## Phase 0：目标与验收标准

### 目标
- 只加载一个 `.ko` 即可工作，不依赖外部 `xdma.ko`
- `/dev/videoX` 可被 `v4l2-ctl`/`ffplay` 正常打开、STREAMON、出帧
- DMA 路径保持 vb2 zero-copy：`vb2-dma-sg` -> `sg_table` -> `xdma_xfer_submit()`

### 验收（最小）
- `modinfo video_cap_pcie_v4l2.ko` 正常
- `sudo insmod video_cap_pcie_v4l2.ko` 后出现 `/dev/video0`（或其它编号）
- `sudo v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=10 --stream-to=out.raw` 成功
- `ffplay -f v4l2 -video_size 1920x1080 -input_format bgr0 -i /dev/video0` 可播放（或至少 `ffmpeg -f null -` 不报错）

## Phase 1：驱动架构落地（骨架）

1. 新建单模块工程目录：`driver/v4l2/kmod/`
2. 把 V4L2 采集驱动从“module_init 单例”改成“PCI 驱动 probe/remove”
3. 在 probe 中直接调用 XDMA core：
   - `xdma_device_open()`：完成 BAR 映射/engine 探测/IRQ 初始化
   - 保存 `struct xdma_dev *xdev` 与用户 BAR 地址
4. 在 remove 中释放资源：
   - `xdma_user_isr_disable()`、`xdma_user_isr_register(..., NULL, ...)`
   - `xdma_device_close()`

## Phase 2：帧同步（VSYNC user IRQ）

1. 注册 user IRQ 回调：`xdma_user_isr_register(xdev, 1<<irq_index, handler, dev)`
2. `handler()` 唤醒采集线程（waitqueue/atomic）
3. `STREAMON` 时 enable 对应 user IRQ：`xdma_user_isr_enable()`
4. `STREAMOFF` 时 disable：`xdma_user_isr_disable()`

## Phase 3：DMA 与 vb2 交付

1. vb2 queue 使用 `vb2_dma_sg_memops`
2. 每帧：
   - 等待 VSYNC
   - `sgt = vb2_dma_sg_plane_desc(vb, 0)`
   - `xdma_xfer_submit(xdev, c2h_channel, false, 0, sgt, true, 1000)`
   - `vb2_buffer_done()`

## Phase 4：可维护性与兼容性

1. 把“XDMA core”限定在最小集合（仅编译 `libxdma.c + xdma_thread.c`）
2. 清晰文档说明：
   - 哪些是来自官方 XDMA
   - 我们依赖哪些 API/结构体
3. 版本策略：
   - 固定 XDMA 源码版本（建议 tag/commit）
   - 固定/验证目标 kernel 版本范围

## Phase 5：后续扩展（不在本阶段实现）

- 增加 YUV422/YUV420/NV12 等像素格式（寄存器/FPGA + V4L2 fmt）
- 多 buffer 深度与异步提交（`xdma_xfer_submit_nowait`）以提升吞吐
- 多设备实例支持（多路卡/多 function）
