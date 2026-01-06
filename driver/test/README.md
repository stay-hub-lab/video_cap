# PCIe Video Capture Driver

Linux kernel driver for PCIe video capture card based on Xilinx XDMA.

## Features

- PCIe Gen2 x4 interface via XDMA (也支持 Gen1 x8)
- AXI-Stream DMA for video data (128-bit @ 125MHz)
- Character device interface for userspace access
- 支持 1080p60 RGB888 视频流
- Extensive debug logging

## Requirements

- Ubuntu 22.04 LTS (kernel 5.15+) 或更高版本
- GCC 11+
- Linux kernel headers

## Build

```bash
# 安装依赖
sudo apt install build-essential linux-headers-$(uname -r)

# 编译驱动模块
cd driver
make

# 编译测试程序
make test_app
```

## Install

```bash
sudo insmod video_cap.ko

# 验证加载成功
lsmod | grep video_cap
dmesg | tail -20

# 检查设备节点
ls -la /dev/video_cap*
```

## Uninstall

```bash
sudo rmmod video_cap
```

## Device Files

| Device          | Description         |
| --------------- | ------------------- |
| /dev/video_cap0 | Main control device |

## Usage

```bash
# 获取版本信息
sudo ./test_app -v

# 获取设备信息 (包含PCIe链路状态)
sudo ./test_app -i

# Dump所有核心寄存器
sudo ./test_app -d

# 读取特定寄存器 (十六进制偏移)
sudo ./test_app -r 0x0000

# 写寄存器
sudo ./test_app -w 0x0004 0x05

# 启动采集 (使能 + 测试模式)
sudo ./test_app -s

# 停止采集
sudo ./test_app -p

# 复位设备
sudo ./test_app -t
```

## Debug

```bash
# 启用动态调试输出
echo 'module video_cap +p' | sudo tee /sys/kernel/debug/dynamic_debug/control

# 实时查看内核日志
dmesg -w

# 查看PCIe设备信息
lspci -vvv -d 10ee:7018
```

## Register Map

| Offset | Name       | Access | Description          |
| ------ | ---------- | ------ | -------------------- |
| 0x0000 | VERSION    | RO     | FPGA 版本号          |
| 0x0004 | CONTROL    | RW     | 控制寄存器           |
| 0x0008 | STATUS     | RO     | 状态寄存器           |
| 0x000C | IRQ_MASK   | RW     | 中断屏蔽             |
| 0x0010 | IRQ_STATUS | RW1C   | 中断状态 (写 1 清除) |
| 0x0100 | VID_FORMAT | RW     | 视频格式配置         |
| 0x0104 | VID_RES    | RO     | 视频分辨率           |
