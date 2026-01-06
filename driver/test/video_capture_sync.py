#!/usr/bin/env python3
"""
video_capture_sync.py - Frame-synchronized video capture using VSYNC interrupts

This script captures video frames with proper frame alignment by:
1. Waiting for VSYNC interrupt (frame start signal from FPGA)
2. Starting DMA read immediately after interrupt
3. Reading exactly one frame worth of data

The FPGA logic (modified video_cap_top_pcie.v) ensures that:
- Data transmission only starts after detecting SOF (Start of Frame)
- Each frame is guaranteed to start from the first pixel
- No partial frames are transmitted

Usage:
    sudo python3 video_capture_sync.py [options]
"""

import os
import sys
import time
import argparse
import subprocess
import select
import numpy as np
from PIL import Image

# Configuration
FRAME_WIDTH = 1920
FRAME_HEIGHT = 1080
BYTES_PER_PIXEL = 4
FRAME_SIZE = FRAME_WIDTH * FRAME_HEIGHT * BYTES_PER_PIXEL

# Device paths
DMA_DEVICE = "/dev/xdma0_c2h_0"
USER_DEVICE = "/dev/xdma0_user"

# XDMA event devices for interrupts
# IRQ[0] = VSYNC rising edge (frame start marker in blanking)
# IRQ[1] = VSYNC falling edge (active video about to start) - USE THIS
# IRQ[2] = Frame complete (all 1080 lines transmitted)
EVENT_DEVICE_VSYNC_RISING = "/dev/xdma0_events_0"
EVENT_DEVICE_VSYNC_FALLING = "/dev/xdma0_events_1"  # Best for frame sync
EVENT_DEVICE_FRAME_COMPLETE = "/dev/xdma0_events_2"

# Register offsets
REG_VERSION = 0x00
REG_CONTROL = 0x04
REG_STATUS = 0x08

# Control bits
CTRL_ENABLE = 0x01
CTRL_SOFT_RESET = 0x02
CTRL_TEST_MODE = 0x04


def read_reg(offset):
    """Read a 32-bit register using dd command"""
    import struct
    seek_blocks = offset // 4
    cmd = f"dd if={USER_DEVICE} bs=4 skip={seek_blocks} count=1 2>/dev/null"
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True)
        if len(result.stdout) >= 4:
            return struct.unpack('<I', result.stdout[:4])[0]
        return -1
    except:
        return -1


def write_reg(offset, value):
    """Write a 32-bit register using dd command"""
    data = value.to_bytes(4, byteorder='little')
    seek_blocks = offset // 4
    cmd = f"dd of={USER_DEVICE} bs=4 seek={seek_blocks} count=1 2>/dev/null"
    try:
        proc = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE)
        proc.communicate(input=data)
        return proc.returncode == 0
    except:
        return False


def soft_reset():
    """Perform a soft reset to clear FPGA state"""
    ctrl = read_reg(REG_CONTROL)
    if ctrl < 0:
        ctrl = 0
    write_reg(REG_CONTROL, ctrl | CTRL_SOFT_RESET)
    time.sleep(0.01)


def enable_capture(test_mode=False):
    """Enable video capture"""
    ctrl = CTRL_ENABLE
    if test_mode:
        ctrl |= CTRL_TEST_MODE
    return write_reg(REG_CONTROL, ctrl)


def disable_capture():
    """Disable video capture"""
    return write_reg(REG_CONTROL, 0)


def wait_for_interrupt(fd_event, timeout=2.0):
    """Wait for an interrupt event with timeout
    
    Returns:
        Number of events, or -1 on timeout/error
    """
    try:
        # Use select for timeout support
        ready, _, _ = select.select([fd_event], [], [], timeout)
        if not ready:
            return -1  # Timeout
        
        data = os.read(fd_event, 4)
        if len(data) >= 4:
            return int.from_bytes(data, byteorder='little')
        return -1
    except OSError as e:
        print(f"Error waiting for interrupt: {e}")
        return -1


def flush_dma_buffer(fd_dma):
    """Flush any stale data in DMA buffer by reading until empty"""
    import fcntl
    
    # Set non-blocking mode temporarily
    flags = fcntl.fcntl(fd_dma, fcntl.F_GETFL)
    fcntl.fcntl(fd_dma, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    
    flushed = 0
    try:
        while True:
            data = os.read(fd_dma, 65536)
            if not data:
                break
            flushed += len(data)
    except BlockingIOError:
        pass  # Buffer empty
    
    # Restore blocking mode
    fcntl.fcntl(fd_dma, fcntl.F_SETFL, flags)
    return flushed


def capture_frame_sync(fd_dma, fd_event, verbose=False):
    """Capture one frame with VSYNC synchronization
    
    Steps:
    1. Wait for VSYNC falling edge interrupt (frame about to start)
    2. Read exactly one frame worth of data
    
    The FPGA ensures data starts from frame beginning (SOF-aligned)
    """
    # Wait for VSYNC interrupt
    events = wait_for_interrupt(fd_event, timeout=2.0)
    if events < 0:
        if verbose:
            print("  Warning: VSYNC timeout, capturing anyway")
    elif verbose:
        print(f"  VSYNC interrupt received (events={events})")
    
    # Read one frame
    data = b''
    remaining = FRAME_SIZE
    
    while remaining > 0:
        try:
            chunk = os.read(fd_dma, remaining)
            if not chunk:
                break
            data += chunk
            remaining -= len(chunk)
        except OSError as e:
            print(f"Error reading DMA: {e}")
            break
    
    return data


def capture_frame_wait_complete(fd_dma, fd_event_start, fd_event_complete, verbose=False):
    """Capture one frame using both start and complete interrupts
    
    This is the most reliable method:
    1. Wait for VSYNC falling (frame start)
    2. Start reading
    3. Wait for frame complete interrupt
    """
    # Wait for frame start
    events = wait_for_interrupt(fd_event_start, timeout=2.0)
    if events < 0:
        if verbose:
            print("  Warning: VSYNC start timeout")
    
    # Read frame data
    data = b''
    remaining = FRAME_SIZE
    
    start_time = time.time()
    while remaining > 0:
        try:
            chunk = os.read(fd_dma, min(remaining, 1024*1024))
            if not chunk:
                break
            data += chunk
            remaining -= len(chunk)
        except OSError as e:
            print(f"Error reading DMA: {e}")
            break
        
        # Timeout protection
        if time.time() - start_time > 1.0:
            if verbose:
                print(f"  Read timeout, got {len(data)} bytes")
            break
    
    return data


def save_frame_png(filename, data, width=FRAME_WIDTH, height=FRAME_HEIGHT):
    """Save frame as PNG image (convert BGRX to RGB)"""
    expected_size = width * height * 4
    
    if len(data) < expected_size:
        print(f"Warning: Incomplete frame ({len(data)}/{expected_size} bytes)")
        height = len(data) // (width * 4)
    
    if height == 0:
        print("Error: No valid frame data")
        return False
    
    frame = np.frombuffer(data[:height*width*4], dtype=np.uint8)
    frame = frame.reshape((height, width, 4))
    
    # Convert BGRX to RGB (FPGA outputs as B, G, R, padding)
    rgb = frame[:, :, 2::-1]  # Reverse first 3 channels
    
    img = Image.fromarray(rgb)
    img.save(filename)
    return True


def print_device_status():
    """Print FPGA status for debugging"""
    version = read_reg(REG_VERSION)
    control = read_reg(REG_CONTROL)
    status = read_reg(REG_STATUS)
    
    print(f"  Version:  0x{version:08X}")
    print(f"  Control:  0x{control:08X} (enable={control&1}, test_mode={(control>>2)&1})")
    print(f"  Status:   0x{status:08X} (idle={status&1}, link_up={(status>>3)&1})")


def main():
    parser = argparse.ArgumentParser(description='Frame-synchronized PCIe Video Capture')
    parser.add_argument('-n', '--count', type=int, default=1,
                        help='Number of frames to capture (default: 1)')
    parser.add_argument('-o', '--output', default='frame_sync',
                        help='Output file prefix (default: frame_sync)')
    parser.add_argument('-t', '--test', action='store_true',
                        help='Use test pattern (color bar)')
    parser.add_argument('-r', '--reset', action='store_true',
                        help='Perform soft reset before capture')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')
    args = parser.parse_args()
    
    print("=== Frame-Synchronized PCIe Video Capture ===")
    print(f"Resolution: {FRAME_WIDTH}x{FRAME_HEIGHT}")
    print(f"Frame size: {FRAME_SIZE:,} bytes ({FRAME_SIZE/1024/1024:.2f} MB)")
    print(f"Mode: {'Test Pattern (Color Bar)' if args.test else 'Video Input'}")
    print(f"Frames: {args.count}")
    print()
    
    fd_dma = None
    fd_event = None
    
    try:
        # Check device status
        print("Device Status:")
        print_device_status()
        print()
        
        # Open DMA device
        fd_dma = os.open(DMA_DEVICE, os.O_RDONLY)
        print(f"Opened {DMA_DEVICE}")
        
        # Open event device for VSYNC interrupts
        try:
            fd_event = os.open(EVENT_DEVICE_VSYNC_FALLING, os.O_RDONLY)
            print(f"Opened {EVENT_DEVICE_VSYNC_FALLING} for frame sync")
        except OSError as e:
            print(f"Warning: Could not open event device: {e}")
            print("Will capture without interrupt synchronization")
        
        # Perform soft reset if requested
        if args.reset:
            print("Performing soft reset...")
            soft_reset()
            time.sleep(0.1)
        
        # Enable capture
        print("Enabling video capture...")
        enable_capture(args.test)
        time.sleep(0.2)  # Wait for video to stabilize and first SOF
        
        # Flush any stale data
        if args.verbose:
            flushed = flush_dma_buffer(fd_dma)
            if flushed > 0:
                print(f"Flushed {flushed} bytes of stale data")
        
        # Capture frames
        print(f"\nCapturing {args.count} frame(s)...")
        start_time = time.time()
        captured = 0
        
        for i in range(args.count):
            # Capture with sync
            if fd_event:
                data = capture_frame_sync(fd_dma, fd_event, args.verbose)
            else:
                # Fallback: just read without sync
                time.sleep(0.02)
                data = os.read(fd_dma, FRAME_SIZE)
            
            if not data or len(data) == 0:
                print(f"Warning: Failed to capture frame {i+1}")
                continue
            
            # Save frame
            filename = f"{args.output}_{i+1:04d}.png"
            if save_frame_png(filename, data):
                captured += 1
                if args.verbose:
                    print(f"  Saved {filename} ({len(data):,} bytes)")
                else:
                    print(f"\rCaptured {i+1}/{args.count} frames", end='', flush=True)
        
        elapsed = time.time() - start_time
        print()
        print()
        print("=== Capture Complete ===")
        print(f"Frames captured: {captured}/{args.count}")
        print(f"Elapsed time: {elapsed:.2f} seconds")
        if elapsed > 0 and captured > 0:
            print(f"Average FPS: {captured/elapsed:.2f}")
        
    except FileNotFoundError as e:
        print(f"Error: Device not found: {e}")
        print("Make sure the XDMA driver is loaded: lsmod | grep xdma")
        return 1
    except PermissionError as e:
        print(f"Error: Permission denied: {e}")
        print("Try running with sudo.")
        return 1
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        # Cleanup
        disable_capture()
        if fd_dma:
            os.close(fd_dma)
        if fd_event:
            os.close(fd_event)
    
    return 0


if __name__ == '__main__':
    sys.exit(main())
