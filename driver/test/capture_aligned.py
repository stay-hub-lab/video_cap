#!/usr/bin/env python3
"""
capture_aligned.py - Capture video frames with software-side frame alignment

Captures multiple frames and finds the correct frame boundary by detecting
the white color bar at the start of each frame.
"""

import os
import sys
import time
import subprocess
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


def enable_capture_colorbar():
    """Enable color bar test pattern"""
    # Control register: 0x05 = enable + test mode
    cmd = f"echo -ne '\\x05\\x00\\x00\\x00' | dd of={USER_DEVICE} bs=4 seek=1 count=1 2>/dev/null"
    subprocess.run(cmd, shell=True)


def disable_capture():
    """Disable capture"""
    cmd = f"echo -ne '\\x00\\x00\\x00\\x00' | dd of={USER_DEVICE} bs=4 seek=1 count=1 2>/dev/null"
    subprocess.run(cmd, shell=True)


def capture_frames(num_frames=3):
    """Capture multiple frames worth of data"""
    total_size = FRAME_SIZE * num_frames
    
    try:
        fd = os.open(DMA_DEVICE, os.O_RDONLY)
        data = os.read(fd, total_size)
        os.close(fd)
        return data
    except Exception as e:
        print(f"Error capturing: {e}")
        return None


def find_frame_start(data, width=FRAME_WIDTH):
    """Find the start of a frame by detecting white color bar followed by correct sequence"""
    row_bytes = width * BYTES_PER_PIXEL
    num_rows = len(data) // row_bytes
    
    # Color bar sequence (BGRX format): White, Yellow, Cyan, Green, Magenta, Red, Blue, Black
    # Check for white -> yellow transition
    for row in range(num_rows - 1):
        offset = row * row_bytes
        
        # Check first pixel (should be white: RGB=255,255,255, BGRX=255,255,255,X)
        b, g, r = data[offset], data[offset+1], data[offset+2]
        
        if r > 250 and g > 250 and b > 250:  # White
            # Check if previous row was black (frame boundary)
            if row > 0:
                prev_offset = (row - 1) * row_bytes
                # Check last part of previous row (should be black)
                black_check_offset = prev_offset + int(width * 0.9) * 4  # Check near end of row
                pb, pg, pr = data[black_check_offset], data[black_check_offset+1], data[black_check_offset+2]
                
                if pr < 10 and pg < 10 and pb < 10:  # Black
                    return row * row_bytes
            else:
                # First row, assume it's a frame start
                return 0
    
    return -1


def extract_frame(data, start_offset, width=FRAME_WIDTH, height=FRAME_HEIGHT):
    """Extract a frame from data starting at given offset"""
    frame_size = width * height * BYTES_PER_PIXEL
    
    if start_offset + frame_size > len(data):
        # Not enough data for full frame
        available = len(data) - start_offset
        height = available // (width * BYTES_PER_PIXEL)
        frame_size = width * height * BYTES_PER_PIXEL
    
    frame_data = data[start_offset:start_offset + frame_size]
    return frame_data, height


def save_frame(filename, data, width=FRAME_WIDTH, height=FRAME_HEIGHT):
    """Save frame as PNG"""
    if len(data) < width * height * 4:
        height = len(data) // (width * 4)
    
    if height == 0:
        return False
    
    frame = np.frombuffer(data[:height*width*4], dtype=np.uint8)
    frame = frame.reshape((height, width, 4))
    
    # Convert BGRX to RGB
    rgb = frame[:, :, 2::-1]
    
    img = Image.fromarray(rgb)
    img.save(filename)
    return True


def main():
    print("=== Aligned Frame Capture ===")
    print(f"Resolution: {FRAME_WIDTH}x{FRAME_HEIGHT}")
    print()
    
    # Enable color bar
    print("Enabling color bar generator...")
    enable_capture_colorbar()
    time.sleep(0.2)
    
    # Capture multiple frames
    print("Capturing 3 frames worth of data...")
    data = capture_frames(3)
    
    if data is None or len(data) == 0:
        print("Error: No data captured")
        disable_capture()
        return 1
    
    print(f"Captured {len(data)} bytes")
    
    # Find frame start
    print("Finding frame boundary...")
    frame_start = find_frame_start(data)
    
    if frame_start < 0:
        print("Warning: Could not find frame boundary, using offset 0")
        frame_start = 0
    else:
        print(f"Found frame start at offset {frame_start} (row {frame_start // (FRAME_WIDTH * 4)})")
    
    # Extract and save frame
    frame_data, actual_height = extract_frame(data, frame_start)
    
    filename = "frame_aligned.png"
    if save_frame(filename, frame_data, FRAME_WIDTH, actual_height):
        print(f"Saved {filename} ({FRAME_WIDTH}x{actual_height})")
    else:
        print("Error: Failed to save frame")
    
    # Also save the raw first frame for comparison
    raw_data = data[:FRAME_SIZE] if len(data) >= FRAME_SIZE else data
    if save_frame("frame_raw.png", raw_data):
        print("Saved frame_raw.png (unaligned)")
    
    # Cleanup
    disable_capture()
    
    print("\nDone!")
    return 0


if __name__ == '__main__':
    sys.exit(main())
