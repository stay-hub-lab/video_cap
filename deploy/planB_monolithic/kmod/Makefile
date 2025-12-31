obj-m += video_cap_pcie_v4l2.o

# Composite module objects (avoid foo.o <- foo.o circular link)
video_cap_pcie_v4l2-objs := video_cap_pcie_v4l2_main.o
video_cap_pcie_v4l2-objs += xdma/libxdma.o
video_cap_pcie_v4l2-objs += xdma/xdma_thread.o

ccflags-y += -I$(src)/../include
ccflags-y += -I$(src)/xdma

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
