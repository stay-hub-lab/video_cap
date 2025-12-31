# 计划：将 Phase-2 顶层模块化并迁移到 Block Design（兼容未来 64-bit XDMA）

目标：把 `fpga/src/hdl/video_cap_top_pcie.v` 中 **`v_vid_in_axi4s_0` 与 `xdma_0` 之间的胶水逻辑** 模块化、可复用，并最终以 BD（Block Design）方式搭建主工程。与此同时，设计时预留 **XDMA AXIS 数据宽度从 128-bit 切换到 64-bit** 的能力。

> 本文只给“计划与架构拆分”，你确认后再开始改 diagram（BD）与 RTL。

---

## A. 现状与痛点（为什么要模块化）

现状（Phase-2）链路：
- 视频像素域（`vid_pixel_clk`）产生 RGB888
- `v_vid_in_axi4s` 负责像素域 -> `axi_aclk` 域，并输出 24-bit AXIS
- 顶层 RTL 负责：
  - SOF 对齐/冲刷/门控（避免帧错位）
  - 24-bit -> 128-bit 打包
  - 深 FIFO 抗 XDMA backpressure
  - VSYNC/帧完成 user IRQ
- `xdma_0` 负责 PCIe + AXI-Lite + AXIS C2H

痛点：
1) 胶水逻辑堆在 top 里，后期很难直接迁移到 BD
2) 24->128 打包与帧对齐策略是“隐式约定”，不利于后续切换像素格式 / 64-bit 宽度
3) VSYNC/IRQ 与帧对齐策略耦合，调试成本高

---

## B. 模块化拆分（建议的 RTL/IP 边界）

建议把 top 中“胶水逻辑”拆成 3~4 个可独立验证的模块（后续可逐步打包成 IP）：

### B1) `video_axis_ingress`（输入侧：帧对齐/冲刷/门控）

输入：来自 `v_vid_in_axi4s` 的 24-bit AXIS（同 `axi_aclk` 域）
- `s_axis_tdata[23:0]`
- `s_axis_tvalid/tready`
- `s_axis_tlast`（行结束）
- `s_axis_tuser`（SOF，若可用）

辅助输入：
- `vsync_in`（已同步到 `axi_aclk` 域的 VSYNC 边沿事件）
- `ctrl_enable/soft_reset`
- `xdma_ready_hint`（例如 XDMA 的 `s_axis_c2h_tready` 或“下游 FIFO 可写”信息）

输出：对齐后的“帧内像素流”（仍是 24-bit AXIS，或直接输出到 packer）

关键行为（参数化）：
- SOF 优先策略：TUSER 优先；fallback 为 VSYNC 触发 + 首次 AXIS handshake 锁定
- 帧外冲刷：强制 `tready=1` 丢弃旧数据直到 SOF
- 运行中异常：若检测到 overflow/underflow（来自 v_vid_in_axi4s）则丢弃当前帧并等待下一次 SOF 重对齐

### B2) `axis_pixel_packer`（打包器：24-bit -> {64|128}-bit）

输入：帧内 24-bit 像素流（同 `axi_aclk` 域）

输出：N-bit AXIS（建议参数化 `C_AXIS_DATA_WIDTH = 64/128`）
- `m_axis_tdata[C_AXIS_DATA_WIDTH-1:0]`
- `m_axis_tkeep[C_AXIS_DATA_WIDTH/8-1:0]`
- `m_axis_tvalid/tready`
- `m_axis_tlast`（行/帧结束）

设计要求：
- 支持不同“像素打包策略”（可编译时选择）：
  - **策略 1（兼容现状 RGB888）**：按像素数打包，末尾 padding，tkeep 反映有效字节
  - **策略 2（推荐后续低成本升级）**：把像素格式提升到 32-bit（例如 XRGB8888），可做到 64-bit=2px、128-bit=4px 无 padding，主机端也更统一
- 对 64-bit XDMA 的考虑：
  - 64-bit 下，每 beat 8 字节：RGB888 会出现 8 不能整除 3 的问题，需要 tkeep 或 padding
  - 如果希望主机端最简单，建议未来转 32-bit 像素格式（或 YUV422 16-bit/pix）

### B3) `axis_elastic_fifo`（抗 backpressure：AXIS FIFO）

功能：吸收 XDMA `tready` 抖动，避免 backpressure 直接影响输入侧。

建议实现方式：
- **优先用 Vivado IP**：AXI4-Stream Data FIFO（可选 BRAM/URAM）
- 参数：深度、几乎满/空阈值、是否支持 `tlast/tkeep`

### B4) `video_irq_gen`（中断发生器：VSYNC/帧完成 -> user IRQ）

输入：
- `vsync_rising/falling`（同步到 `axi_aclk`）
- `frame_complete`（例如从 packer/FIFO 看到“帧尾 last 已被下游接受”）

输出：
- `usr_irq_req[N-1:0]`
- `usr_irq_ack[N-1:0]`

参数化：
- 哪些事件映射到哪个 user IRQ bit（例如 bit0=VSYNC rising / bit1=frame complete）
- 是否用电平保持到 ack（现状是保持）

---

## C. Block Design 迁移建议（从 RTL top 到 BD）

BD 中的典型连接建议：

1) 时钟/复位
- `xdma_0/axi_aclk` 作为 AXI 域主时钟
- `xdma_0/axi_aresetn` 作为 AXI 域主复位
- `clk_wiz` 产生 `vid_pixel_clk`

2) 视频输入
- `color_bar` 未来可替换为外部视频源（HDMI/SDI/MIPI 等）
- `v_vid_in_axi4s` IP 仍可作为“视频 -> AXIS”桥接（或未来替换为更标准的视频 IP）

3) 自定义模块（打包为 IP）
- 把 `video_axis_ingress + axis_pixel_packer + axis_elastic_fifo + video_irq_gen`：
  - 先以 RTL 模块形式验证
  - 再逐个打包成 IP（推荐最终合成一个“VideoCaptureBridge IP”，减少 BD 里连线复杂度）

4) AXI-Lite 寄存器
- 现状 `register_bank` 可继续保持 RTL
- 后续可替换为 `AXI GPIO/AXI4-Lite register slice + 自定义寄存器 IP`

---

## D. 64-bit XDMA 兼容策略

需要提前明确两件事：

1) **XDMA 的 `s_axis_c2h_tdata` 宽度**是由 XDMA IP 参数决定的（64/128/256…），不是软件决定。
2) 软件端（V4L2 驱动）读取的是“线性 bytes 流”，所以必须保证 FPGA 端的打包规则稳定且可描述。

建议兼容方案（按推荐优先级）：

- 方案 D1（推荐）：像素格式升级到 32-bit（XRGB/XBGR）  
  - 64-bit：2 像素/beat；128-bit：4 像素/beat
  - `tkeep` 永远全 1（满字节），最简单、最稳
  - 软件端也更容易直接当作 `bgr0/xbgr` 播放

- 方案 D2（保持 RGB888）：依赖 `tkeep` 或 padding  
  - 需要清晰定义每 beat 内有效字节与 padding 字节位置
  - 软件端可能需要额外去 padding（不推荐）

- 方案 D3（未来加 YUV422）：16-bit/pix 更适合带宽与对齐  
  - 64-bit：4 像素/beat；128-bit：8 像素/beat
  - 对低延时与 PCIe 带宽更友好

---

## E. 交付物与实施步骤（建议）

### Phase 1：纯 RTL 模块化（不改 BD）
交付物：
- `fpga/src/hdl/bridge/` 目录（新建）
  - `video_axis_ingress.v`
  - `axis_pixel_packer.v`（参数化宽度 64/128）
  - `video_irq_gen.v`
  - 先用 Vivado AXIS FIFO IP（或保留现有 FIFO 但封装成模块）
- `video_cap_top_pcie.v` 变为“只做实例化与连线”的薄 top

验收：
- 现有 bitstream 行为一致：能采集、能 VSYNC 同步、遇到 backpressure 不乱帧

### Phase 2：打包自定义 IP + BD 组装
交付物：
- 1 个或多个自定义 IP（推荐最终合并为 1 个）
- 新的 block design：顶层只保留 `video_cap_top_bd_wrapper.v`

验收：
- BD 工程可一键生成/综合/实现
- 硬件行为与 Phase-1 一致

### Phase 3：可配置数据宽度（64/128）
交付物：
- `axis_pixel_packer` 支持 `C_AXIS_DATA_WIDTH=64/128`
- BD 中可切换 XDMA 数据宽度并联动 packer 参数
- 文档明确打包格式与 host 端解析方式

验收：
- 64-bit/128-bit 两种配置均可采集稳定

---

## F. 需要你确认的问题（确认后再改 diagram）

1) 你希望最终的“主机端像素格式”是什么？
- 继续 RGB888（简单但对齐麻烦）
- 升级到 32-bit（推荐，最省事）
- 直接上 YUV422（带宽最优，但软件/显示链路要同步改）

2) VSYNC 想用哪个 user IRQ 事件作为“帧同步”？
- VSYNC rising（帧开始）
- VSYNC falling（有效区开始）
- frame_complete（帧尾）

3) 未来要支持的 XDMA 宽度目标：
- 必须 64-bit
- 64/128 都要
- 先固定 128，后续再做 64

你确认以上选择后，我再开始：
- 新建 `bridge/` 模块并把 top 变薄
- 同步修改 Vivado BD（diagram）与脚本（`add_pcie.tcl` 等）

