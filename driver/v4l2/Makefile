obj-m += video_cap_v4l2.o

ccflags-y += -I$(src)/../../linux/dma_ip_drivers-master/XDMA/linux-kernel/include
ccflags-y += -I$(src)/../../linux/dma_ip_drivers-master/XDMA/linux-kernel/xdma

KBUILD_EXTRA_SYMBOLS += $(src)/../../linux/dma_ip_drivers-master/XDMA/linux-kernel/xdma/Module.symvers

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
