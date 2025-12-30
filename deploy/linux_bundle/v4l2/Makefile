obj-m += video_cap_v4l2.o

ccflags-y += -I$(src)/../include
ccflags-y += -I$(src)/../xdma

KBUILD_EXTRA_SYMBOLS += $(src)/../xdma/Module.symvers

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
