#!/usr/bin/env bash
set -euo pipefail

make

# V4L2/vb2 dependencies are usually modules; load them first to avoid "Unknown symbol" on insmod.
sudo modprobe -a videodev videobuf2_common videobuf2_v4l2 videobuf2_dma_sg || true

# Example parameters:
# - c2h_channel: XDMA C2H channel index
# - irq_index:   XDMA user IRQ index wired to VSYNC
# - test_pattern: enable FPGA color bar (if supported by your bitstream)
sudo insmod video_cap_pcie_v4l2.ko test_pattern=1 c2h_channel=0 irq_index=1

v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --all
