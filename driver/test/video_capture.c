/*
 * video_capture.c - Video capture application using XDMA with interrupt support
 *
 * This application captures video frames from the PCIe video capture card
 * using XDMA driver with interrupt-based frame synchronization.
 *
 * Interrupt mapping:
 *   - IRQ 0: VSYNC rising edge (frame start)
 *   - IRQ 1: VSYNC falling edge (active video start)
 *   - IRQ 2: Frame complete (DMA transfer done)
 *
 * Build: gcc -o video_capture video_capture.c -lpthread -O2
 * Usage: sudo ./video_capture [options]
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>


/* Configuration */
#define FRAME_WIDTH 1920
#define FRAME_HEIGHT 1080
#define BYTES_PER_PIXEL 4
#define FRAME_SIZE (FRAME_WIDTH * FRAME_HEIGHT * BYTES_PER_PIXEL)

#define NUM_BUFFERS 4 /* Number of frame buffers for ring buffer */
#define DMA_DEVICE "/dev/xdma0_c2h_0"
#define USER_DEVICE "/dev/xdma0_user"
#define EVENT_DEVICE_0 "/dev/xdma0_events_0" /* VSYNC rising */
#define EVENT_DEVICE_1 "/dev/xdma0_events_1" /* VSYNC falling */
#define EVENT_DEVICE_2 "/dev/xdma0_events_2" /* Frame complete */

/* Register offsets */
#define REG_VERSION 0x00
#define REG_CONTROL 0x04
#define REG_STATUS 0x08

/* Control bits */
#define CTRL_ENABLE (1 << 0)
#define CTRL_TEST_MODE (1 << 2)

/* Global variables */
static int running = 1;
static int fd_dma = -1;
static int fd_user = -1;
static int fd_event = -1;
static uint8_t *frame_buffers[NUM_BUFFERS];
static int current_buffer = 0;
static int frames_captured = 0;
static struct timeval start_time;

/* Signal handler */
void signal_handler(int sig) {
  printf("\nReceived signal %d, stopping...\n", sig);
  running = 0;
}

/* Write register */
int write_reg(int fd, uint32_t offset, uint32_t value) {
  if (lseek(fd, offset, SEEK_SET) < 0) {
    perror("lseek failed");
    return -1;
  }
  if (write(fd, &value, 4) != 4) {
    perror("write failed");
    return -1;
  }
  return 0;
}

/* Read register */
int read_reg(int fd, uint32_t offset, uint32_t *value) {
  if (lseek(fd, offset, SEEK_SET) < 0) {
    perror("lseek failed");
    return -1;
  }
  if (read(fd, value, 4) != 4) {
    perror("read failed");
    return -1;
  }
  return 0;
}

/* Enable video capture */
int enable_capture(int fd, int test_mode) {
  uint32_t ctrl = CTRL_ENABLE;
  if (test_mode) {
    ctrl |= CTRL_TEST_MODE;
  }
  return write_reg(fd, REG_CONTROL, ctrl);
}

/* Disable video capture */
int disable_capture(int fd) { return write_reg(fd, REG_CONTROL, 0); }

/* Wait for interrupt (blocking) */
int wait_for_interrupt(int fd_event, uint32_t *events) {
  ssize_t ret = read(fd_event, events, sizeof(*events));
  if (ret < 0) {
    if (errno == EINTR) {
      return 0; /* Interrupted by signal */
    }
    perror("read event failed");
    return -1;
  }
  return 1;
}

/* Capture one frame via DMA */
int capture_frame(int fd_dma, uint8_t *buffer, size_t size) {
  if (lseek(fd_dma, 0, SEEK_SET) < 0) {
    perror("lseek failed");
    return -1;
  }

  ssize_t total = 0;
  while (total < size) {
    ssize_t ret = read(fd_dma, buffer + total, size - total);
    if (ret < 0) {
      if (errno == EINTR)
        continue;
      perror("DMA read failed");
      return -1;
    }
    if (ret == 0)
      break; /* EOF or underflow */
    total += ret;
  }

  return total;
}

/* Save frame to file */
int save_frame(const char *filename, uint8_t *buffer, size_t size) {
  FILE *fp = fopen(filename, "wb");
  if (!fp) {
    perror("fopen failed");
    return -1;
  }

  size_t written = fwrite(buffer, 1, size, fp);
  fclose(fp);

  return (written == size) ? 0 : -1;
}

/* Save frame as PPM image */
int save_frame_ppm(const char *filename, uint8_t *buffer, int width,
                   int height) {
  FILE *fp = fopen(filename, "wb");
  if (!fp) {
    perror("fopen failed");
    return -1;
  }

  fprintf(fp, "P6\n%d %d\n255\n", width, height);

  /* Convert BGRX to RGB */
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int offset = (y * width + x) * 4;
      uint8_t b = buffer[offset + 0];
      uint8_t g = buffer[offset + 1];
      uint8_t r = buffer[offset + 2];
      fputc(r, fp);
      fputc(g, fp);
      fputc(b, fp);
    }
  }

  fclose(fp);
  return 0;
}

/* Print usage */
void print_usage(const char *prog) {
  printf("Usage: %s [options]\n", prog);
  printf("Options:\n");
  printf("  -n <count>    Number of frames to capture (0=continuous, "
         "default=10)\n");
  printf("  -o <prefix>   Output file prefix (default=frame)\n");
  printf("  -t            Use test pattern (color bar)\n");
  printf("  -i            Use interrupt for frame sync (default)\n");
  printf("  -p            Use polling for frame sync\n");
  printf("  -s            Save frames to files\n");
  printf("  -v            Verbose output\n");
  printf("  -h            Print this help\n");
}

int main(int argc, char *argv[]) {
  int opt;
  int frame_count = 10;
  int test_mode = 0;
  int use_interrupt = 1;
  int save_frames = 0;
  int verbose = 0;
  const char *output_prefix = "frame";

  /* Parse command line */
  while ((opt = getopt(argc, argv, "n:o:tipsvh")) != -1) {
    switch (opt) {
    case 'n':
      frame_count = atoi(optarg);
      break;
    case 'o':
      output_prefix = optarg;
      break;
    case 't':
      test_mode = 1;
      break;
    case 'i':
      use_interrupt = 1;
      break;
    case 'p':
      use_interrupt = 0;
      break;
    case 's':
      save_frames = 1;
      break;
    case 'v':
      verbose = 1;
      break;
    case 'h':
    default:
      print_usage(argv[0]);
      return (opt == 'h') ? 0 : 1;
    }
  }

  printf("=== PCIe Video Capture ===\n");
  printf("Resolution: %dx%d\n", FRAME_WIDTH, FRAME_HEIGHT);
  printf("Frame size: %d bytes\n", FRAME_SIZE);
  printf("Mode: %s\n", test_mode ? "Test Pattern" : "Video Input");
  printf("Sync: %s\n", use_interrupt ? "Interrupt" : "Polling");
  printf("Frames: %d%s\n", frame_count,
         frame_count == 0 ? " (continuous)" : "");
  printf("\n");

  /* Install signal handler */
  signal(SIGINT, signal_handler);
  signal(SIGTERM, signal_handler);

  /* Allocate frame buffers */
  for (int i = 0; i < NUM_BUFFERS; i++) {
    frame_buffers[i] = (uint8_t *)aligned_alloc(4096, FRAME_SIZE);
    if (!frame_buffers[i]) {
      perror("Failed to allocate frame buffer");
      goto cleanup;
    }
  }

  /* Open DMA device */
  fd_dma = open(DMA_DEVICE, O_RDONLY);
  if (fd_dma < 0) {
    perror("Failed to open DMA device");
    goto cleanup;
  }

  /* Open user device for register access */
  fd_user = open(USER_DEVICE, O_RDWR);
  if (fd_user < 0) {
    perror("Failed to open user device");
    goto cleanup;
  }

  /* Open event device for interrupts */
  if (use_interrupt) {
    fd_event = open(EVENT_DEVICE_2, O_RDONLY); /* Frame complete interrupt */
    if (fd_event < 0) {
      perror("Failed to open event device, falling back to polling");
      use_interrupt = 0;
    }
  }

  /* Read version */
  uint32_t version;
  if (read_reg(fd_user, REG_VERSION, &version) == 0) {
    printf("FPGA Version: 0x%08X\n", version);
  }

  /* Enable video capture */
  printf("Enabling video capture...\n");
  if (enable_capture(fd_user, test_mode) < 0) {
    fprintf(stderr, "Failed to enable capture\n");
    goto cleanup;
  }

  /* Wait for video to stabilize */
  usleep(100000); /* 100ms */

  /* Start timing */
  gettimeofday(&start_time, NULL);

  /* Main capture loop */
  printf("Starting capture...\n");
  while (running && (frame_count == 0 || frames_captured < frame_count)) {
    uint32_t events;
    int bytes;

    /* Wait for frame sync */
    if (use_interrupt) {
      int ret = wait_for_interrupt(fd_event, &events);
      if (ret < 0)
        break;
      if (ret == 0)
        continue; /* Interrupted */
    }

    /* Capture frame */
    uint8_t *buffer = frame_buffers[current_buffer];
    bytes = capture_frame(fd_dma, buffer, FRAME_SIZE);

    if (bytes < 0) {
      fprintf(stderr, "Capture failed\n");
      break;
    }

    if (bytes < FRAME_SIZE) {
      if (verbose) {
        printf("Warning: Partial frame %d bytes (expected %d)\n", bytes,
               FRAME_SIZE);
      }
    }

    frames_captured++;

    /* Save frame if requested */
    if (save_frames) {
      char filename[256];
      snprintf(filename, sizeof(filename), "%s_%04d.ppm", output_prefix,
               frames_captured);
      save_frame_ppm(filename, buffer, FRAME_WIDTH, FRAME_HEIGHT);
      if (verbose) {
        printf("Saved %s\n", filename);
      }
    }

    /* Progress */
    if (verbose || (frames_captured % 60 == 0)) {
      struct timeval now;
      gettimeofday(&now, NULL);
      double elapsed = (now.tv_sec - start_time.tv_sec) +
                       (now.tv_usec - start_time.tv_usec) / 1000000.0;
      double fps = frames_captured / elapsed;
      printf("\rCaptured %d frames (%.1f fps)   ", frames_captured, fps);
      fflush(stdout);
    }

    /* Next buffer */
    current_buffer = (current_buffer + 1) % NUM_BUFFERS;
  }

  /* Calculate final statistics */
  struct timeval end_time;
  gettimeofday(&end_time, NULL);
  double elapsed = (end_time.tv_sec - start_time.tv_sec) +
                   (end_time.tv_usec - start_time.tv_usec) / 1000000.0;

  printf("\n\n=== Capture Complete ===\n");
  printf("Frames captured: %d\n", frames_captured);
  printf("Elapsed time: %.2f seconds\n", elapsed);
  printf("Average FPS: %.2f\n", frames_captured / elapsed);
  printf("Data rate: %.2f MB/s\n",
         (frames_captured * FRAME_SIZE) / (elapsed * 1024 * 1024));

cleanup:
  /* Disable capture */
  if (fd_user >= 0) {
    disable_capture(fd_user);
    close(fd_user);
  }

  /* Close devices */
  if (fd_dma >= 0)
    close(fd_dma);
  if (fd_event >= 0)
    close(fd_event);

  /* Free buffers */
  for (int i = 0; i < NUM_BUFFERS; i++) {
    if (frame_buffers[i])
      free(frame_buffers[i]);
  }

  return 0;
}
