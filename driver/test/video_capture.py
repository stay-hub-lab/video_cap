#!/usr/bin/env python3
"""
video_capture.py - Simple video capture script using XDMA

This script captures video frames from the PCIe video capture card
and saves them as PNG images.
echo -ne '\x05\x00\x00\x00' | sudo dd of=/dev/xdma0_user bs=4 seek=1 count=1
sudo python3 video_capture.py -t -i -n 5 -v
Usage:
    sudo python3 video_capture.py [options]
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
EVENT_DEVICE_VSYNC_DEFAULT = "/dev/xdma0_events_1"  # often maps to usr_irq_req[1] (vsync falling)
EVENT_DEVICE_VSYNC_CANDIDATES = [
    EVENT_DEVICE_VSYNC_DEFAULT,
    "/dev/xdma0_events_0",
]

# Register offsets
REG_CONTROL = 0x04

# Control bits
CTRL_ENABLE = 0x01
CTRL_TEST_MODE = 0x04


def write_reg_dd(offset, value):
    """Write a 32-bit register using dd command"""
    # Convert value to bytes (little-endian)
    data = value.to_bytes(4, byteorder='little')
    
    # Use dd to write
    seek_blocks = offset // 4
    cmd = f"dd of={USER_DEVICE} bs=4 seek={seek_blocks} count=1 2>/dev/null"
    
    try:
        proc = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE)
        proc.communicate(input=data)
        return proc.returncode == 0
    except Exception as e:
        print(f"Error writing register: {e}")
        return False


def enable_capture(test_mode=False):
    """Enable video capture"""
    ctrl = CTRL_ENABLE
    if test_mode:
        ctrl |= CTRL_TEST_MODE
    return write_reg_dd(REG_CONTROL, ctrl)


def disable_capture():
    """Disable video capture"""
    return write_reg_dd(REG_CONTROL, 0)


def wait_for_interrupt(fd_event): 
    """Wait for an interrupt event (blocking)"""
    try:
        data = os.read(fd_event, 4)
        if len(data) >= 4:
            return int.from_bytes(data, byteorder='little')
        return -1
    except OSError as e: 
        print(f"Error waiting for interrupt: {e}") 
        return -1 


def open_event_device(preferred_path=None):
    """Open an XDMA event device, returning (fd, path) or (None, None)."""
    candidates = []
    if preferred_path:
        candidates.append(preferred_path)
    candidates.extend(EVENT_DEVICE_VSYNC_CANDIDATES)

    tried = set()
    for path in candidates:
        if not path or path in tried:
            continue
        tried.add(path)
        try:
            fd = os.open(path, os.O_RDONLY)
            return fd, path
        except OSError:
            continue

    return None, None


def capture_frame_dd(output_file, size=FRAME_SIZE):
    """Capture one frame via DMA using dd command"""
    cmd = f"dd if={DMA_DEVICE} of={output_file} bs={size} count=1 2>/dev/null"
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True)
        return result.returncode == 0
    except Exception as e:
        print(f"Error capturing frame: {e}")
        return False


def capture_frame(fd_dma, size=FRAME_SIZE, timeout_s=2.0, chunk_size=None): 
    """Capture one frame via DMA (read exactly `size` bytes). 
 
    Note: XDMA stream reads may return short reads even in blocking mode. 
    If we don't drain the full frame, the next capture will start mid-stream 
    and images will appear shifted/misaligned. 
    """ 
    if chunk_size is None:
        chunk_size = size  # default: try to read the whole frame per sys-call
    buf = bytearray() 
    read_calls = 0
    deadline = None if timeout_s is None else (time.monotonic() + float(timeout_s)) 
 
    try: 
        while len(buf) < size: 
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                rlist, _, _ = select.select([fd_dma], [], [], remaining)
                if not rlist:
                    continue

            to_read = min(size - len(buf), chunk_size) 
            chunk = os.read(fd_dma, to_read) 
            read_calls += 1
            if not chunk: 
                break 
            buf.extend(chunk) 
 
        return bytes(buf), read_calls 
    except OSError as e: 
        print(f"Error capturing frame: {e}") 
        return None, 0


def save_frame_png(filename, data, width=FRAME_WIDTH, height=FRAME_HEIGHT):
    """Save frame as PNG image (convert BGRX to RGB)"""
    if len(data) < width * height * 4:
        print(f"Warning: Incomplete frame data ({len(data)} bytes)")
        height = len(data) // (width * 4)
    
    if height == 0:
        print("Error: No valid frame data")
        return False
    
    frame = np.frombuffer(data[:height*width*4], dtype=np.uint8)
    frame = frame.reshape((height, width, 4))
    
    # Convert BGRX to RGB
    rgb = frame[:, :, 2::-1]  # Reverse first 3 channels
    
    img = Image.fromarray(rgb)
    img.save(filename)
    return True


def main():
    parser = argparse.ArgumentParser(description='PCIe Video Capture')
    parser.add_argument('-n', '--count', type=int, default=1,
                        help='Number of frames to capture (default: 1)')
    parser.add_argument('-o', '--output', default='frame',
                        help='Output file prefix (default: frame)')
    parser.add_argument('-t', '--test', action='store_true',
                        help='Use test pattern (color bar)')
    parser.add_argument('-i', '--interrupt', action='store_true', 
                        help='Use interrupt for frame sync') 
    parser.add_argument('--event', default=None,
                        help='XDMA event device path (default: auto-detect)')
    parser.add_argument('-d', '--delay', type=float, default=0.02, 
                        help='Delay between frames in seconds (default: 0.02)') 
    parser.add_argument('--chunk', type=int, default=FRAME_SIZE,
                        help='Max bytes per DMA read() call (default: frame size)') 
    parser.add_argument('--skip', type=int, default=0,
                        help='Discard N frames after enable (default: 0)') 
    parser.add_argument('-v', '--verbose', action='store_true', 
                        help='Verbose output') 
    args = parser.parse_args() 
    
    print("=== PCIe Video Capture ===")
    print(f"Resolution: {FRAME_WIDTH}x{FRAME_HEIGHT}")
    print(f"Frame size: {FRAME_SIZE} bytes")
    print(f"Mode: {'Test Pattern' if args.test else 'Video Input'}")
    print(f"Sync: {'Interrupt' if args.interrupt else 'Polling'}")
    print(f"Frames: {args.count}")
    print()
    
    fd_dma = None
    fd_event = None
    
    try:
        # Open DMA device
        fd_dma = os.open(DMA_DEVICE, os.O_RDONLY)
        print(f"Opened {DMA_DEVICE}")
        
        # Open event device if using interrupt 
        if args.interrupt: 
            fd_event, event_path = open_event_device(args.event)
            if fd_event is not None:
                print(f"Opened {event_path} for VSYNC interrupts")
            else:
                print("Warning: Could not open any XDMA event device, falling back to polling mode")
                args.interrupt = False
        
        # Enable capture
        print("Enabling video capture...")
        if not enable_capture(args.test): 
            print("Warning: Could not enable capture via register, trying anyway...") 
        time.sleep(0.1)  # Wait for video to stabilize 

        # Optional warm-up: discard a few frames to let the stream/driver settle.
        if args.skip > 0:
            if args.verbose:
                print(f"Discarding {args.skip} frame(s) for warm-up...")
            for s in range(args.skip):
                if args.interrupt and fd_event:
                    _ = wait_for_interrupt(fd_event)
                else:
                    time.sleep(args.delay)
                _data, _reads = capture_frame(fd_dma, chunk_size=args.chunk)
                if args.verbose:
                    got = 0 if _data is None else len(_data)
                    print(f"  Warm-up {s+1}/{args.skip}: {got} bytes, read() calls: {_reads}")
         
        # Capture frames 
        print(f"Capturing {args.count} frame(s)...") 
        start_time = time.time() 
        frames_saved = 0 
        
        for i in range(args.count):
            # Wait for frame sync
            if args.interrupt and fd_event:
                events = wait_for_interrupt(fd_event)
                if args.verbose:
                    print(f"  Interrupt received: {events}")
            else: 
                time.sleep(args.delay) 
             
            # Capture frame 
            data, read_calls = capture_frame(fd_dma, chunk_size=args.chunk) 
            if args.verbose:
                print(f"  DMA read() calls: {read_calls}")
             
            if data is None or len(data) == 0: 
                print(f"Warning: Failed to capture frame {i+1}") 
                continue 
            if len(data) != FRAME_SIZE:
                print(f"Error: Short/partial DMA read ({len(data)} bytes), aborting to avoid stream desync")
                break
            
            # Save frame
            filename = f"{args.output}_{i+1:04d}.png"
            if save_frame_png(filename, data):
                if args.verbose:
                    print(f"  Saved {filename} ({len(data)} bytes)")
                else:
                    print(f"\rCaptured {i+1}/{args.count} frames", end='')
                frames_saved += 1
        
        elapsed = time.time() - start_time
        print()
        print()
        print("=== Capture Complete ===")
        print(f"Frames captured: {frames_saved}")
        print(f"Elapsed time: {elapsed:.2f} seconds")
        if elapsed > 0:
            print(f"Average FPS: {frames_saved/elapsed:.2f}")
        
    except FileNotFoundError as e:
        print(f"Error: Device not found: {e}")
        print("Make sure the XDMA driver is loaded.")
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
