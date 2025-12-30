# PCIe Video Capture Card FPGA Project

## Project Overview

PCIe video capture card based on Xilinx XC7K480TFFG1156-2 FPGA.

### Key Features

- **Target Device**: XC7K480TFFG1156-2 (Kintex-7)
- **PCIe Interface**: Gen2 x8 (5.0 GT/s)
- **XDMA Mode**: AXI-Stream (low latency)
- **Video Source**: Color bar generator (1080P60)
- **Video Format**: RGB888
- **Tool Version**: Vivado 2024.2

## Development Phases

| Phase       | Content                   | Status         |
| ----------- | ------------------------- | -------------- |
| **Phase 1** | Color bar generator + LED | ✅ Complete    |
| **Phase 2** | XDMA Stream mode + PCIe   | 🔄 In Progress |
| **Phase 3** | DDR3 frame buffer (MIG)   | ⏳ Pending     |
| **Phase 4** | Linux V4L2 driver         | ⏳ Pending     |

## Directory Structure

```
fpga/
├── README.md
├── constraints/
│   ├── pins.xdc              # Phase 1 pins
│   ├── pcie.xdc              # Phase 2 PCIe + all pins
│   └── timing.xdc            # Timing constraints
├── project/                  # Vivado project (auto-generated)
├── scripts/
│   ├── create_project.tcl    # Phase 1: Create project
│   ├── add_pcie.tcl          # Phase 2: Add XDMA
│   ├── add_mig.tcl           # Phase 3: Add DDR3
│   └── build.tcl             # Build automation
└── src/hdl/
    ├── video_cap_top.v       # Phase 1 top (no PCIe)
    ├── video_cap_top_pcie.v  # Phase 2 top (with XDMA)
    ├── common/
    │   └── register_bank.v
    └── video_pattern_gen/
        ├── video_pattern_gen.v
        ├── timing_gen.v
        ├── color_bar_gen.v
        └── vid_to_axi_stream.v
```

## Quick Start

### Phase 1: Color Bar Generator (Completed)

```tcl
cd G:/Xilinx/XC7K480T/project/video_cap/fpga/scripts
source create_project.tcl
launch_runs synth_1 -jobs 8
wait_on_run synth_1
```

### Phase 2: Add PCIe (XDMA Stream Mode)

```tcl
# Add XDMA IP
source add_pcie.tcl

# Wait for IP generation to complete

# Add new top module file
add_files -norecurse ../src/hdl/video_cap_top_pcie.v

# Change top module
set_property top video_cap_top_pcie [current_fileset]

# Use PCIe constraints (replaces Phase 1 constraints)
set_property is_enabled false [get_files pins.xdc]
set_property is_enabled true [get_files pcie.xdc]

# Update and synthesize
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 8
```

## Data Flow (Phase 2)

```
[Color Bar Gen] --> [AXI-Stream FIFO] --> [XDMA C2H] --> [PCIe] --> [Host Memory]
   148.5MHz            CDC FIFO           axi_aclk       Gen2x8
   1080P60           (async)             ~250MHz         4GB/s
```

## Register Map (BAR0)

| Offset | Name       | Access | Description                              |
| ------ | ---------- | ------ | ---------------------------------------- |
| 0x0000 | VERSION    | RO     | Version (0x20251221)                     |
| 0x0004 | CONTROL    | RW     | [0]=Enable [1]=Reset [2]=TestMode        |
| 0x0008 | STATUS     | RO     | [0]=Idle [1]=MIG [2]=Overflow [3]=LinkUp |
| 0x000C | IRQ_MASK   | RW     | Interrupt mask                           |
| 0x0010 | IRQ_STATUS | RW1C   | Interrupt status                         |
| 0x0100 | VID_FMT    | RW     | Video format                             |
| 0x0104 | VID_RES    | RO     | Resolution (1920x1080)                   |

## LED Indicators

| LED  | Phase 1        | Phase 2       |
| ---- | -------------- | ------------- |
| LED0 | Heartbeat      | Heartbeat     |
| LED1 | PLL Locked     | PCIe Link Up  |
| LED2 | Frame Activity | Video Enabled |

## Reference Projects

| Project                  | Reference        |
| ------------------------ | ---------------- |
| XC7K480T_PCIE_Test_ex    | PCIe XDMA config |
| XC7K480T_MicroBlaze_Test | DDR3 MIG config  |

## Known Issues

1. **XDMA Port Names**: Actual port names may differ from generated IP.
   Check example design after running `add_pcie.tcl`.

2. **Clock Domain Crossing**: vid_to_axi_stream uses async FIFO for CDC.

## Next Steps

1. Run `source add_pcie.tcl` in Vivado
2. Wait for XDMA IP generation (~5-10 minutes)
3. Verify XDMA ports match video_cap_top_pcie.v
4. Synthesize and implement
5. Test on hardware with XDMA driver
