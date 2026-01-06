# FPGA 工程说明（Phase-2：PCIe XDMA Stream 低延时采集）

本目录对应 Kintex-7（`XC7K480TFFG1156-2`）的视频采集 FPGA 工程。当前阶段（Phase-2）目标是：

- 以 **AXI-Stream** 方式把视频数据直接送入 XDMA C2H（低延时、无帧缓存）
- 主机侧通过 V4L2 驱动以 `/dev/videoX` 读取帧数据（见 `driver/v4l2/`）

> 说明：本文重点解释 `fpga/src/hdl/video_cap_top_pcie.v` 中 **`v_vid_in_axi4s_0` 与 `xdma_0` 之间的“胶水逻辑”** 的模块关系、时钟/复位、数据通路和中断通路；后续要做 Block Design 化时，这部分逻辑需要模块化/封装。

---

## 更新说明（已模块化）
从当前版本开始，`v_vid_in_axi4s_0 -> XDMA C2H` 之间的“胶水逻辑”已封装成独立模块：`fpga/src/hdl/bridge/video_cap_c2h_bridge.v`，`video_cap_top_pcie.v` 默认走 bridge 的实现路径。
- 默认：使用 `video_cap_c2h_bridge`（top 更薄，便于后续 BD 替换/复用）
- 回退：如需对照旧实现，可在综合/仿真时定义 `VIDEO_CAP_KEEP_LEGACY_GLUE`（会启用 top 内保留的 legacy 逻辑）

## 1. 顶层与主要模块

Phase-2 顶层：`fpga/src/hdl/video_cap_top_pcie.v`

该顶层主要由以下模块组成（按出现顺序/作用归类）：

### 1.1 时钟/复位与 PCIe 物理层输入

- `IBUFDS_GTE2 refclk_ibuf`
  - 将 PCIe 参考时钟 `sys_clk_p/n` 输入给 XDMA/PCIe 子系统使用
- `IBUF sys_reset_n_ibuf`
  - 处理 `sys_rst_n`（PCIe 复位，低有效）
- `IBUF ibuf_sys_clk_200m`
  - 处理板上 `sys_clk_200m`（200MHz）
- `clk_wiz_video u_clk_wiz_video`
  - 从 200MHz 产生视频像素时钟（例如 1080p60 的 148.5MHz），并给出 `locked`

### 1.2 XDMA（PCIe + AXI-Lite + AXI-Stream）

- `xdma_0 u_xdma_0`
  - 产生用户时钟/复位：`axi_aclk`、`axi_aresetn`
  - AXI-Lite Master：用于主机访问用户寄存器（BAR 对应寄存器空间）
  - AXI-Stream：
    - `s_axis_c2h_*_0`：卡到主机（视频数据通道）
    - `m_axis_h2c_*_0`：主机到卡（当前未使用）
  - 用户中断：`usr_irq_req[3:0]` / `usr_irq_ack[3:0]`

### 1.3 寄存器（AXI-Lite 从设备）

- `register_bank u_register_bank`
  - 工作在 `axi_aclk` 域
  - 接收 XDMA 的 AXI-Lite 访问，提供 `CONTROL/STATUS/...` 等寄存器
  - 输出控制信号（例如 `ctrl_enable/ctrl_soft_reset/ctrl_test_mode`）
  - 状态输入（例如 FIFO overflow/underflow 相关状态等）

### 1.4 视频源（目前为彩条）

- `color_bar u_color_bar`
  - 在像素时钟 `vid_pixel_clk` 域产生：
    - `vid_data[23:0]`（RGB888）
    - `vid_vsync/vid_hsync/vid_de/vid_field`

### 1.5 视频输入到 AXI-Stream（Xilinx IP）

- `v_vid_in_axi4s_0 u_vid_in_axi4s`
  - **输入域**：`vid_io_in_clk = vid_pixel_clk`（视频侧）
  - **输出域**：`aclk = axi_aclk`（PCIe/XDMA 用户侧）
  - 输出 AXI-Stream（24-bit）：
    - `axis_vid_tdata[23:0]`
    - `axis_vid_tvalid/tready`
    - `axis_vid_tlast`（行结束）
    - `axis_vid_tuser`（可配置为 SOF/帧标志；不同配置可能行为不同）
  - 同时会产生 overflow/underflow 等状态信号（顶层对这些信号做 CDC 后用于状态/丢帧重对齐）

---

## 2. 数据通路（v_vid_in_axi4s_0 -> XDMA）

从 `v_vid_in_axi4s_0` 输出的 `axis_vid_*`（24-bit AXIS）到 `xdma_0` 的 `s_axis_c2h_*`（当前 128-bit AXIS）之间，顶层实现了几段关键“胶水逻辑”，目的只有一个：**在不做帧缓存的前提下，尽量保证帧边界对齐、抗 backpressure、遇错可自恢复**。

下面按数据流顺序说明：

### 2.1 SOF（帧起始）对齐策略

在低延时 stream 场景，最怕“帧边界错位”：主机认为一帧开始，但 FPGA 输出的第一笔数据其实是上一帧尾巴或中间位置。

顶层做了“两级 SOF 事件”策略：

1) **优先使用 AXIS TUSER(SOF)**  
如果 `v_vid_in_axi4s` 配置为输出 SOF，则 `axis_vid_tuser` 与 `tdata` 同域同链路，理论上对齐最准确。

2) **Fallback：用 VSYNC 边沿触发 + “第一笔 AXIS 握手”作为 SOF**  
VSYNC 在 `axi_aclk` 域做同步后，只作为“触发条件”；真正把 SOF 锁定到某个像素样本，仍然以 `axis_vid_tvalid && axis_vid_tready` 的那一次握手为准，从而吸收 `v_vid_in_axi4s` 内部 FIFO/延迟带来的不确定性。

最终顶层会生成 `sof_detected`，并用它驱动后面的“对齐后才开始输出一帧”状态机。

### 2.2 帧输出门控（与主机读取节奏对齐）

顶层引入 `capture_armed / frame_in_progress / frame_active` 这类状态，核心思想是：

- **只有当主机开始拉数据（XDMA 拉高 `s_axis_c2h_tready_0`）且输出路径空闲**，才允许开始输出一帧
- 如果检测到 `v_vid_in_axi4s` overflow/underflow 等异常，立即丢弃当前帧，等待下一次 SOF 重新对齐

这保证了：
- 主机侧每次开始读取时，帧起点尽量一致（低延时同时不乱帧）
- 遇到 backpressure 或异常，不会在错误状态里越跑越偏

### 2.3 24-bit 像素打包为 128-bit（与 XDMA 数据宽度匹配）

`axis_vid_tdata` 是 RGB888（24-bit / pixel），但 XDMA C2H stream 接口常见是 64/128-bit（取决于 IP 配置）。

当前 `video_cap_top_pcie.v` 的实现是：

- 在 `axi_aclk` 域缓存若干个 24-bit 像素（例如 4 个像素）
- 组成一个 128-bit 的 `pack_word_data`
- 生成对应的 `tlast`（通常以“行尾/帧尾”规则决定；当前实现里会结合 `axis_vid_tlast` 与行计数/帧计数做判定）

> 重要：这一段就是未来要模块化的核心之一——它决定了“像素格式/对齐/带宽利用率/主机端解析方式”。

### 2.4 BRAM FIFO（吸收 XDMA 的 tready 抖动）

XDMA 会对 `s_axis_c2h_tready_0` 做 backpressure（例如内部队列、PCIe credit、驱动侧读取节奏变化），如果直接把 backpressure 传回视频侧，会导致：

- `v_vid_in_axi4s` 更容易 overflow/underflow
- 帧内出现不连续、丢像素、错位等问题

因此顶层在 `axi_aclk` 域放置了一个“深 BRAM FIFO”（示意信号名：`c2h_bram_fifo_*`）：

- 写入端：来自“像素打包”输出（128-bit + tlast）
- 读取端：直接驱动 XDMA `s_axis_c2h_*`
- `s_axis_c2h_tvalid` 由 FIFO 非空产生
- `s_axis_c2h_tready` 由 XDMA 产生

同时，顶层还对 `axis_vid_tready` 做了精心的计算：

- 帧内：在 128-bit 边界处（例如 4 个像素聚齐时）才真正受 FIFO 写入能力影响
- 帧外：强制 `axis_vid_tready = 1`，持续“冲刷”`v_vid_in_axi4s` 内部 FIFO，直到看到新的 SOF 再进入帧内模式

这段逻辑的目标是：**把 backpressure 尽量“挡在视频侧之外”**，让视频输入链路更稳定。

---

## 3. 中断通路（VSYNC/帧完成 -> usr_irq_req）

顶层在 `axi_aclk` 域同步 VSYNC，并生成 user IRQ：

- `usr_irq_req[0]`：VSYNC 上升沿（帧开始）
- `usr_irq_req[1]`：VSYNC 下降沿（接近有效数据开始，具体取决于视频时序）
- `usr_irq_req[2]`：帧传输完成（例如检测到 `s_axis_c2h_tlast_0` 且握手成功）
- `usr_irq_req[3]`：保留

`usr_irq_req` 是“电平保持直到 ACK”的方式：`usr_irq_ack[i]` 到来后清零对应位。

> 主机侧驱动（例如 planB）如果把 `irq_index=1` 作为 VSYNC，则需要确保 FPGA 侧选择的 user IRQ 线与该 index 对应（例如用 `usr_irq_req[1]` 还是 `[0]`，以你的定义为准）。

---

## 4. 时钟域与复位域

本顶层至少包含两个关键时钟域：

- **视频像素域**：`vid_pixel_clk`（由 `clk_wiz_video` 产生）
  - `color_bar` 等视频源在此域运行
- **PCIe/XDMA 用户域**：`axi_aclk`（由 XDMA IP 产生）
  - `register_bank`、AXIS 打包、BRAM FIFO、IRQ 逻辑等均在此域运行

跨域点：
- `v_vid_in_axi4s` 内部负责从像素域到 AXI 域的转换/缓存
- VSYNC 也会被同步到 `axi_aclk` 域用于 IRQ 与帧对齐辅助

复位：
- 以 `axi_aresetn` 作为 AXI 域主复位
- `ctrl_soft_reset`、`ctrl_enable` 等也会参与 AXI 域逻辑复位/清空（例如 BRAM FIFO 清空、重新对齐）

---

## 5. 文件结构（与本说明相关）

```
fpga/
  README.md
  src/hdl/
    video_cap_top_pcie.v           # Phase-2 顶层（本说明重点）
    video_cap_top.v                # Phase-1 顶层（无 PCIe）
    common/register_bank.v         # AXI-Lite 寄存器
    video_pattern_gen/*            # 视频测试源与 video->axis 辅助
    color_bar.v                    # 彩条（旧版/参考，当前工程可能已迁移到其它实现）
```

---

## 6. 下一步：Block Design 化的模块化封装

后续如果你希望把 “v_vid_in_axi4s_0 与 XDMA 之间的胶水逻辑” 全部做成 BD 里的 IP Block，
建议先把顶层中以下逻辑抽成独立 RTL 模块（并最终打包成 IP）：

- 帧对齐/冲刷/门控状态机（SOF 策略、异常重对齐）
- 24-bit 像素到 N-bit（64/128）AXIS 打包器（参数化）
- AXIS BRAM FIFO（可直接用 Vivado 自带 AXIS Data FIFO IP 代替自写 FIFO）
- VSYNC/帧完成中断发生器（可参数化映射到 user IRQ bit）

详细计划见：`fpga/PLAN_block_design.md`（你确认后再开始改 diagram/工程结构）。
