/*
 * video_cap.c - PCIe视频采集驱动源码
 *
 * Copyright (C) 2024
 */

#include <linux/cdev.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/time.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#include "video_cap.h"
#include "video_cap_regs.h"

/*
 * 设备上下文结构体
 */
struct video_cap_dev {
  struct pci_dev *pdev; /* PCI设备结构 */
  void __iomem *bar0;   /* BAR0内核映射地址 (用户寄存器 + XDMA) */
  unsigned long bar0_len;

  dev_t dev_num;         /* 设备号 (主/次) */
  struct cdev cdev;      /* 字符设备结构 */
  struct class *class;   /* 设备类 */
  struct device *device; /* 设备结构 */

  spinlock_t lock; /* 主要锁 */

  /* 设备状态 */
  int usage_count;

  /* 中断处理 */
  int irq;
};

/*
 * 全局变量
 */
static int major_number;
static struct class *video_cap_class = NULL;
#define CLASS_NAME "video_cap"

/*
 * 寄存器访问辅助函数
 */
static inline u32 reg_read(struct video_cap_dev *dev, u32 offset) {
  return ioread32(dev->bar0 + offset);
}

static inline void reg_write(struct video_cap_dev *dev, u32 offset, u32 val) {
  iowrite32(val, dev->bar0 + offset);
}

/*
 * IOCTL 处理函数
 */
static long video_cap_ioctl(struct file *file, unsigned int cmd,
                            unsigned long arg) {
  struct video_cap_dev *dev = file->private_data;
  int ret = 0;

  switch (cmd) {
  case VIDEO_CAP_GET_VERSION: {
    struct video_cap_version ver;
    u32 fpga_ver_reg;

    memset(&ver, 0, sizeof(ver));
    ver.major = 1;
    ver.minor = 0;
    ver.patch = 0;

    /* 读取FPGA版本 */
    fpga_ver_reg = reg_read(dev, REG_VERSION);
    ver.fpga_version = fpga_ver_reg;

    /* 读取编译日期/时间 (暂时模拟) */
    // TODO: 如果有实际寄存器则从寄存器读取
    snprintf(ver.build_date, 16, "20241222");

    if (copy_to_user((void __user *)arg, &ver, sizeof(ver)))
      return -EFAULT;
    break;
  }

  case VIDEO_CAP_GET_INFO: {
    struct video_cap_info info;
    struct pci_dev *pdev = dev->pdev;
    u16 link_status;

    memset(&info, 0, sizeof(info));
    info.vendor_id = pdev->vendor;
    info.device_id = pdev->device;
    info.subsystem_id = pdev->subsystem_device;
    info.bar0_size = dev->bar0_len;

    /* 获取PCIe链路信息 */
    pcie_capability_read_word(pdev, PCI_EXP_LNKSTA, &link_status);
    info.pcie_link_speed = (link_status & PCI_EXP_LNKSTA_CLS) * 25; // x2.5 GT/s
    info.pcie_link_width =
        (link_status & PCI_EXP_LNKSTA_NLW) >> PCI_EXP_LNKSTA_NLW_SHIFT;

    /* 默认功能特性 */
    info.max_width = VIDEO_WIDTH_1080P;
    info.max_height = VIDEO_HEIGHT_1080P;
    info.capabilities = CAP_VIDEO_CAPTURE | CAP_READ_WRITE;

    if (copy_to_user((void __user *)arg, &info, sizeof(info)))
      return -EFAULT;
    break;
  }

  case VIDEO_CAP_READ_REG: {
    struct video_cap_reg reg;

    if (copy_from_user(&reg, (void __user *)arg, sizeof(reg)))
      return -EFAULT;

    /* 安全检查: 仅允许访问BAR0范围 */
    if (reg.offset >= dev->bar0_len || (reg.offset & 3))
      return -EINVAL;

    reg.value = reg_read(dev, reg.offset);

    if (copy_to_user((void __user *)arg, &reg, sizeof(reg)))
      return -EFAULT;
    break;
  }

  case VIDEO_CAP_WRITE_REG: {
    struct video_cap_reg reg;

    if (copy_from_user(&reg, (void __user *)arg, sizeof(reg)))
      return -EFAULT;

    if (reg.offset >= dev->bar0_len || (reg.offset & 3))
      return -EINVAL;

    reg_write(dev, reg.offset, reg.value);
    break;
  }

  case VIDEO_CAP_RESET: {
    /* FPGA 软复位 */
    u32 ctrl = reg_read(dev, REG_CONTROL);
    reg_write(dev, REG_CONTROL, ctrl | CTRL_SOFT_RESET);

    /* 等待复位清除 (FPGA内自动清除) */
    udelay(10);
    break;
  }

  default:
    return -ENOTTY;
  }

  return ret;
}

/*
 * 文件操作函数
 */
static int video_cap_open(struct inode *inode, struct file *file) {
  struct video_cap_dev *dev;

  dev = container_of(inode->i_cdev, struct video_cap_dev, cdev);
  file->private_data = dev;

  spin_lock(&dev->lock);
  dev->usage_count++;
  spin_unlock(&dev->lock);

  return 0;
}

static int video_cap_release(struct inode *inode, struct file *file) {
  struct video_cap_dev *dev = file->private_data;

  spin_lock(&dev->lock);
  dev->usage_count--;
  spin_unlock(&dev->lock);

  return 0;
}

static struct file_operations fops = {
    .owner = THIS_MODULE,
    .open = video_cap_open,
    .release = video_cap_release,
    .unlocked_ioctl = video_cap_ioctl,
};

/*
 * PCIe 探测函数
 */
static int video_cap_probe(struct pci_dev *pdev,
                           const struct pci_device_id *id) {
  struct video_cap_dev *dev;
  int ret;
  int bar = 0; /* XDMA 使用 BAR0 用于 AXI-Lite 和 DMA 控制 */

  dev_info(&pdev->dev, "Probing Video Capture Device\n");

  /* 启用PCI设备 */
  ret = pci_enable_device(pdev);
  if (ret) {
    dev_err(&pdev->dev, "Failed to enable PCI device\n");
    return ret;
  }

  /* 启用总线主控 */
  pci_set_master(pdev);

  /* 分配设备结构 */
  dev = kzalloc(sizeof(*dev), GFP_KERNEL);
  if (!dev) {
    ret = -ENOMEM;
    goto disable_pci;
  }

  dev->pdev = pdev;
  spin_lock_init(&dev->lock);
  pci_set_drvdata(pdev, dev);

  /* 请求 MMIO 资源 */
  ret = pci_request_regions(pdev, DRIVER_NAME);
  if (ret) {
    dev_err(&pdev->dev, "Failed to request regions\n");
    goto free_dev;
  }

  /* 映射 BAR0 */
  dev->bar0_len = pci_resource_len(pdev, bar);
  dev->bar0 = pci_iomap(pdev, bar, 0);
  if (!dev->bar0) {
    dev_err(&pdev->dev, "Failed to map BAR0\n");
    ret = -ENOMEM;
    goto release_regions;
  }

  dev_info(&pdev->dev, "BAR0 mapped at %p (length %lu)\n", dev->bar0,
           dev->bar0_len);

  /* 初始化字符设备 */
  ret = alloc_chrdev_region(&dev->dev_num, 0, 1, DRIVER_NAME);
  if (ret < 0) {
    dev_err(&pdev->dev, "Failed to allocate major number\n");
    goto unmap_bar;
  }

  major_number = MAJOR(dev->dev_num);

  cdev_init(&dev->cdev, &fops);
  dev->cdev.owner = THIS_MODULE;

  ret = cdev_add(&dev->cdev, dev->dev_num, 1);
  if (ret) {
    dev_err(&pdev->dev, "Failed to add cdev\n");
    goto unregister_chrdev;
  }

  /* 创建设备节点 /dev/video_cap0 */
  if (video_cap_class) {
    dev->device = device_create(video_cap_class, NULL, dev->dev_num, NULL,
                                DRIVER_NAME "0");
    if (IS_ERR(dev->device)) {
      dev_err(&pdev->dev, "Failed to create device node\n");
      ret = PTR_ERR(dev->device);
      goto del_cdev;
    }
  }

  /* 打印 FPGA 版本 */
  dev_info(&pdev->dev, "FPGA Version: 0x%08X\n", reg_read(dev, REG_VERSION));

  return 0;

del_cdev:
  cdev_del(&dev->cdev);
unregister_chrdev:
  unregister_chrdev_region(dev->dev_num, 1);
unmap_bar:
  pci_iounmap(pdev, dev->bar0);
release_regions:
  pci_release_regions(pdev);
free_dev:
  kfree(dev);
disable_pci:
  pci_disable_device(pdev);
  return ret;
}

static void video_cap_remove(struct pci_dev *pdev) {
  struct video_cap_dev *dev = pci_get_drvdata(pdev);

  dev_info(&pdev->dev, "Removing Video Capture Device\n");

  if (dev) {
    device_destroy(video_cap_class, dev->dev_num);
    cdev_del(&dev->cdev);
    unregister_chrdev_region(dev->dev_num, 1);

    if (dev->bar0)
      pci_iounmap(pdev, dev->bar0);

    pci_release_regions(pdev);
    pci_disable_device(pdev);
    kfree(dev);
  }
}

/*
 * PCI 设备ID表
 */
static const struct pci_device_id pci_ids[] = {
    {PCI_DEVICE(XDMA_VENDOR_ID, XDMA_DEVICE_ID)},
    {
        0,
    }};
MODULE_DEVICE_TABLE(pci, pci_ids);

/*
 * PCI 驱动结构体
 */
static struct pci_driver video_cap_driver = {
    .name = DRIVER_NAME,
    .id_table = pci_ids,
    .probe = video_cap_probe,
    .remove = video_cap_remove,
};

/*
 * 模块 初始化/退出
 */
static int __init video_cap_init(void) {
  int ret;

  printk(KERN_INFO "video_cap: Module loading...\n");

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
  video_cap_class = class_create(CLASS_NAME);
#else
  video_cap_class = class_create(THIS_MODULE, CLASS_NAME);
#endif

  if (IS_ERR(video_cap_class)) {
    printk(KERN_ERR "video_cap: Failed to create class\n");
    return PTR_ERR(video_cap_class);
  }

  ret = pci_register_driver(&video_cap_driver);
  if (ret) {
    printk(KERN_ERR "video_cap: Failed to register PCI driver\n");
    class_destroy(video_cap_class);
    return ret;
  }

  return 0;
}

static void __exit video_cap_exit(void) {
  pci_unregister_driver(&video_cap_driver);

  if (video_cap_class)
    class_destroy(video_cap_class);

  printk(KERN_INFO "video_cap: Module unloaded\n");
}

module_init(video_cap_init);
module_exit(video_cap_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Antigravity for User");
MODULE_DESCRIPTION("PCIe Video Capture Driver for XC7K480T");
MODULE_VERSION(DRIVER_VERSION);
