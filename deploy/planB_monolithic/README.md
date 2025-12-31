# 方案B：单模块（内置 XDMA Core）+ V4L2 视频采集

目标：把本项目当前“V4L2 驱动依赖外部 `xdma.ko`”的方案，升级为 **单一内核模块**：

- 只需要加载一个 `.ko`（例如 `video_cap_pcie_v4l2.ko`）
- 模块内部集成 XDMA core（`xdma_device_open/xdma_xfer_submit/xdma_user_isr_*`）
- 不再要求系统预先加载/安装官方 `xdma.ko`（也不再需要 `EXPORT_SYMBOL_GPL(xdma_xfer_submit)` 这类补丁链路）
- 用户态仍然通过 `/dev/videoX`（V4L2）访问采集

本目录只存放方案B的文档与代码（方案B的实现位于 `deploy/planB_monolithic/kmod/`）。

## 代码来源（XDMA vendoring）

本目录已把 XDMA 源码完整复制到 `deploy/planB_monolithic/kmod/xdma/`，因此把整个 `deploy/planB_monolithic/` 拷贝到 Linux 后即可独立编译（不依赖仓库其它目录）。

说明：
- `kmod/xdma/` 内文件来自 Xilinx 官方 XDMA Linux kernel driver 源码目录（与 `deploy/linux_bundle/xdma/` 同源）。
- 方案B仅在一个模块里“集成使用”这些源码（不再要求外部先加载 `xdma.ko`）。

## 你现在会得到什么

- `TASK_PLAN.md`：方案B任务计划（按阶段拆解，便于迭代）
- `kmod/`：方案B的单模块内核驱动骨架（PCIe probe + V4L2 + vb2 + XDMA core 调用）

## 下一步建议

1) 先在目标 Linux 机器上编译并确认基本链路跑通：
- `insmod video_cap_pcie_v4l2.ko`
- `v4l2-ctl --list-devices`
- `ffplay -f v4l2 ... -i /dev/video0`

2) 然后再做像素格式（YUV422）/性能优化。
