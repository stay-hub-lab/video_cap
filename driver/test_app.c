/*
 * test_app.c - PCIe视频采集驱动测试程序
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "video_cap.h"
#include "video_cap_regs.h"

#define DEV_NAME "/dev/video_cap0"

void print_usage(const char *prog_name) {
  printf("用法: %s [选项]\n", prog_name);
  printf("选项:\n");
  printf("  -v            获取版本信息\n");
  printf("  -i            获取设备信息\n");
  printf("  -d            Dump所有核心寄存器\n");
  printf("  -r <offset>   读寄存器 (十六进制偏移)\n");
  printf("  -w <off> <val> 写寄存器 (十六进制偏移, 十六进制值)\n");
  printf("  -s            开始视频采集 (使能 + 测试模式)\n");
  printf("  -p            停止视频采集\n");
  printf("  -t            复位设备\n");
  printf("  -h            显示此帮助\n");
}

int main(int argc, char *argv[]) {
  int fd;
  int opt;
  struct video_cap_version ver;
  struct video_cap_info info;
  struct video_cap_reg reg;

  fd = open(DEV_NAME, O_RDWR);
  if (fd < 0) {
    perror("打开设备失败");
    return 1;
  }

  while ((opt = getopt(argc, argv, "vidr:w:spth")) != -1) {
    switch (opt) {
    case 'v':
      if (ioctl(fd, VIDEO_CAP_GET_VERSION, &ver) < 0) {
        perror("IOCTL GET_VERSION 失败");
      } else {
        printf("驱动版本:   %d.%d.%d\n", ver.major, ver.minor, ver.patch);
        printf("FPGA版本:   0x%08X\n", ver.fpga_version);
        printf("编译日期:   %s\n", ver.build_date);
      }
      break;

    case 'i':
      if (ioctl(fd, VIDEO_CAP_GET_INFO, &info) < 0) {
        perror("IOCTL GET_INFO 失败");
      } else {
        printf("供应商ID:     0x%04X\n", info.vendor_id);
        printf("设备ID:       0x%04X\n", info.device_id);
        printf("链路速度:     %d.%d GT/s\n", info.pcie_link_speed / 10,
               info.pcie_link_speed % 10);
        printf("链路宽度:     x%d\n", info.pcie_link_width);
        printf("BAR0大小:     %u 字节\n", info.bar0_size);
        printf("最大分辨率:   %dx%d\n", info.max_width, info.max_height);
      }
      break;

    case 'd':
      printf("=== 寄存器 Dump ===\n");
      reg.offset = REG_VERSION;
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) == 0)
        printf("VERSION    [0x%04X] = 0x%08X\n", reg.offset, reg.value);
      reg.offset = REG_CONTROL;
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) == 0) {
        printf("CONTROL    [0x%04X] = 0x%08X", reg.offset, reg.value);
        printf(" (EN=%d, RST=%d, TEST=%d)\n", (reg.value & CTRL_ENABLE) ? 1 : 0,
               (reg.value & CTRL_SOFT_RESET) ? 1 : 0,
               (reg.value & CTRL_TEST_MODE) ? 1 : 0);
      }
      reg.offset = REG_STATUS;
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) == 0) {
        printf("STATUS     [0x%04X] = 0x%08X", reg.offset, reg.value);
        printf(" (IDLE=%d, MIG=%d, OVFL=%d, LINK=%d)\n",
               (reg.value & STS_IDLE) ? 1 : 0,
               (reg.value & STS_MIG_CALIB) ? 1 : 0,
               (reg.value & STS_FIFO_OVERFLOW) ? 1 : 0,
               (reg.value & STS_PCIE_LINK_UP) ? 1 : 0);
      }
      reg.offset = REG_IRQ_MASK;
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) == 0)
        printf("IRQ_MASK   [0x%04X] = 0x%08X\n", reg.offset, reg.value);
      reg.offset = REG_IRQ_STATUS;
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) == 0)
        printf("IRQ_STATUS [0x%04X] = 0x%08X\n", reg.offset, reg.value);
      reg.offset = REG_VID_FORMAT;
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) == 0)
        printf("VID_FORMAT [0x%04X] = 0x%08X\n", reg.offset, reg.value);
      reg.offset = REG_VID_RESOLUTION;
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) == 0)
        printf("VID_RES    [0x%04X] = 0x%08X (%dx%d)\n", reg.offset, reg.value,
               (reg.value >> 16) & 0xFFFF, reg.value & 0xFFFF);
      break;

    case 'r':
      reg.offset = strtoul(optarg, NULL, 16);
      if (ioctl(fd, VIDEO_CAP_READ_REG, &reg) < 0) {
        perror("IOCTL READ_REG 失败");
      } else {
        printf("寄存器[0x%04X] = 0x%08X\n", reg.offset, reg.value);
      }
      break;

    case 'w':
      reg.offset = strtoul(optarg, NULL, 16);
      if (optind < argc) {
        reg.value = strtoul(argv[optind], NULL, 16);
        optind++;
      } else {
        fprintf(stderr, "缺少写入值\n");
        break;
      }

      if (ioctl(fd, VIDEO_CAP_WRITE_REG, &reg) < 0) {
        perror("IOCTL WRITE_REG 失败");
      } else {
        printf("写入 0x%08X 到 寄存器[0x%04X]\n", reg.value, reg.offset);
      }
      break;

    case 's':
      // 使能 + 测试模式 (0x05)
      reg.offset = REG_CONTROL;
      reg.value = CTRL_ENABLE | CTRL_TEST_MODE;
      if (ioctl(fd, VIDEO_CAP_WRITE_REG, &reg) < 0) {
        perror("启动采集失败");
      } else {
        printf("采集已启动 (CONTROL=0x%08X)\n", reg.value);
      }
      break;

    case 'p':
      // 停止 (0x00)
      reg.offset = REG_CONTROL;
      reg.value = 0;
      if (ioctl(fd, VIDEO_CAP_WRITE_REG, &reg) < 0) {
        perror("停止采集失败");
      } else {
        printf("采集已停止\n");
      }
      break;

    case 't':
      if (ioctl(fd, VIDEO_CAP_RESET, 0) < 0) {
        perror("复位设备失败");
      } else {
        printf("设备复位已触发\n");
      }
      break;

    case 'h':
    default:
      print_usage(argv[0]);
      break;
    }
  }

  if (argc == 1) {
    print_usage(argv[0]);
  }

  close(fd);
  return 0;
}
