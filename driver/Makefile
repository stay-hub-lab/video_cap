obj-m += video_cap.o

# Compiler flags
ccflags-y := -std=gnu99 -Wno-declaration-after-statement

# Kernel build directory
KDIR ?= /lib/modules/$(shell uname -r)/build

all: modules apps

modules:
	make -C $(KDIR) M=$(PWD) modules

apps: test_app video_capture

clean:
	make -C $(KDIR) M=$(PWD) clean
	rm -f test_app video_capture

test_app: test_app.c
	gcc -o test_app test_app.c -Wall -O2

video_capture: video_capture.c
	gcc -o video_capture video_capture.c -Wall -O2 -lpthread

.PHONY: all modules apps clean

