# 多通道寄存器改造建议（支持并发采集）

目标：让 `/dev/video0`、`/dev/video1`… 对应的 **多个 C2H 通道可以同时 STREAMON**，互不影响（各自 `VID_FORMAT/ENABLE/TEST_MODE/SOFT_RESET` 独立）。

当前问题：`register_bank` 的 `REG_CONTROL/REG_VID_FORMAT` 是全局寄存器，多个 `/dev/videoX` 同时开启会互相覆盖硬件配置，因此驱动不得不互斥（兼容模式）。

本文件给出一套**后向兼容**的寄存器扩展：保留现有单通道寄存器不变，同时新增 per-channel 寄存器块 + 能力寄存器 `REG_CAPS`，驱动可自动识别并启用并发模式。

## 1) 全局寄存器（保持兼容）

继续保留（不改地址、不改位定义）：

- `REG_VERSION` `0x0000`
- `REG_CONTROL` `0x0004`（legacy：全局 enable/test 等；新设计中可保留为 master enable，也可以仅用于兼容）
- `REG_STATUS` `0x0008`
- `REG_IRQ_MASK` `0x000C`
- `REG_IRQ_STATUS` `0x0010`
- `REG_VID_FORMAT` `0x0100`（legacy：ch0 或全局）

新增一个只读能力寄存器：

- `REG_CAPS` `0x0014`（RO）

### `REG_CAPS` 建议位定义

```
[0]   CAPS_FEAT_PER_CH_CTRL  : 每 channel 独立 CTRL（ENABLE/TEST/SOFT_RESET）
[1]   CAPS_FEAT_PER_CH_FMT   : 每 channel 独立 VID_FORMAT
[2]   CAPS_FEAT_PER_CH_STS   : 每 channel 独立 STATUS/overflow/underflow（可选）
[7:4] reserved
[15:8]  CAPS_CH_COUNT        : 支持的 channel 数（>=1）
[31:16] CAPS_CH_STRIDE       : per-channel block stride（bytes，>=0x20，4B 对齐）
```

驱动策略：
- 若 `CAPS_FEAT_PER_CH_CTRL` 与 `CAPS_FEAT_PER_CH_FMT` 同时置位，且 `CH_COUNT/STRIDE` 合法，则 **允许并发采集**，并且写 per-channel 寄存器。
- 否则进入兼容模式：仍写 `REG_CONTROL/REG_VID_FORMAT`（全局），并对 STREAMON 做互斥保护。

## 2) per-channel 寄存器块（新增）

建议在 user BAR 里开辟独立空间，避免与现有地址冲突：

- `REG_CH_BASE = 0x1000`
- `CH_STRIDE = REG_CAPS[31:16]`（推荐默认 `0x100`）

每个 channel 的基址：

```
CH_BASE(ch) = REG_CH_BASE + ch * CH_STRIDE
```

### 每 channel 的最小寄存器集合（建议）

| 偏移 | 名称 | 方向 | 说明 |
|---:|---|---|---|
| 0x00 | `CH_CONTROL` | RW | 与 `REG_CONTROL` 同位定义（ENABLE/TEST/SOFT_RESET…），但作用域仅限该 channel |
| 0x04 | `CH_VID_FORMAT` | RW | 与 `REG_VID_FORMAT` 同枚举（RGB888/YUV422…），仅限该 channel |
| 0x08 | `CH_STATUS` | RO | 可选：该 channel 的溢出/欠流等状态（便于多路排查） |

> 备注：如果后续需要 per-channel 分辨率、像素计数等，也建议放在这个 block 内继续扩展。

## 3) 中断（XDMA user IRQ）与多通道

并发多通道时，通常**每个通道需要 1 路 VSYNC/帧事件 IRQ**，建议：
- `usr_irq_req[i]` 对应 channel i 的 VSYNC（或帧完成事件）
- XDMA IP 的 “Number of User Interrupts” 需要 `>= 通道数`

你现在配置了 4 路 user IRQ：做 2 路/4 路通道都够用；如果未来要 8 路，就要把 XDMA 的 user IRQ 数量也增加到 8（并在硬件里连出来）。

## 4) 软硬件改动清单（最小集）

FPGA（必须）：
- register_bank 增加 `REG_CAPS`
- register_bank 增加 per-channel block（至少 `CH_CONTROL`、`CH_VID_FORMAT`）
- 每路视频通路/bridge 使用本通道的 `CH_CONTROL/CH_VID_FORMAT`

驱动（配套）：
- probe 时读 `REG_CAPS`，决定是否启用并发模式
- 并发模式：每个 `/dev/videoX` 写对应 `CH_CONTROL/CH_VID_FORMAT`
- 兼容模式：仍写全局寄存器，并对 STREAMON 做互斥（避免相互覆盖）

