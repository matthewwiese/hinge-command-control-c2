#!/usr/bin/env python3
"""
Simple Visual Data Encoder
Encodes binary data as colored blocks in an image.
Similar to JAB Code but simplified.

Usage:
    python visenc.py encode input.bin output.png
    python visenc.py decode input.png output.bin
"""

import sys
import math
import struct
import zlib
import numpy as np
from PIL import Image

# 8 colors = 3 bits per block
COLORS = np.array([
    [0, 0, 0],        # 0 - Black
    [0, 0, 255],      # 1 - Blue
    [0, 255, 0],      # 2 - Green
    [0, 255, 255],    # 3 - Cyan
    [255, 0, 0],      # 4 - Red
    [255, 0, 255],    # 5 - Magenta
    [255, 255, 0],    # 6 - Yellow
    [255, 255, 255],  # 7 - White
], dtype=np.uint8)

BLOCK_SIZE = 8  # Pixels per color block
HEADER_SIZE = 8  # 4 bytes length + 4 bytes CRC


def encode(data: bytes, output_path: str):
    """Encode binary data to image."""
    # Header: length (4B) + CRC32 (4B)
    crc = zlib.crc32(data) & 0xFFFFFFFF
    payload = struct.pack('>I', len(data)) + struct.pack('>I', crc) + data
    
    # Convert bytes to 3-bit symbols
    bits = ''.join(f'{b:08b}' for b in payload)
    while len(bits) % 3:
        bits += '0'
    
    symbols = [int(bits[i:i+3], 2) for i in range(0, len(bits), 3)]
    
    # Calculate grid size (square-ish)
    n = len(symbols)
    width = math.ceil(math.sqrt(n))
    height = math.ceil(n / width)
    
    # Create image
    img = np.zeros((height * BLOCK_SIZE, width * BLOCK_SIZE, 3), dtype=np.uint8)
    
    for i, sym in enumerate(symbols):
        row, col = divmod(i, width)
        y, x = row * BLOCK_SIZE, col * BLOCK_SIZE
        img[y:y+BLOCK_SIZE, x:x+BLOCK_SIZE] = COLORS[sym]
    
    # Fill remaining blocks with pattern
    for i in range(len(symbols), width * height):
        row, col = divmod(i, width)
        y, x = row * BLOCK_SIZE, col * BLOCK_SIZE
        img[y:y+BLOCK_SIZE, x:x+BLOCK_SIZE] = COLORS[(row + col) % 8]
    
    Image.fromarray(img).save(output_path)
    print(f"Encoded {len(data)} bytes -> {output_path} ({width*BLOCK_SIZE}x{height*BLOCK_SIZE}px)")


def decode(input_path: str, output_path: str):
    """Decode image back to binary data."""
    img = np.array(Image.open(input_path).convert('RGB'))
    
    height = img.shape[0] // BLOCK_SIZE
    width = img.shape[1] // BLOCK_SIZE
    
    # Sample center of each block and find nearest color
    symbols = []
    for row in range(height):
        for col in range(width):
            y, x = row * BLOCK_SIZE + BLOCK_SIZE//2, col * BLOCK_SIZE + BLOCK_SIZE//2
            pixel = img[y, x]
            # Find nearest color
            dists = np.sum((COLORS.astype(int) - pixel.astype(int))**2, axis=1)
            symbols.append(np.argmin(dists))
    
    # Convert symbols to bytes
    bits = ''.join(f'{s:03b}' for s in symbols)
    data = bytes(int(bits[i:i+8], 2) for i in range(0, len(bits) - 7, 8))
    
    # Parse header
    length = struct.unpack('>I', data[:4])[0]
    stored_crc = struct.unpack('>I', data[4:8])[0]
    payload = data[8:8+length]
    
    # Verify
    actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
    if actual_crc == stored_crc:
        print(f"CRC OK ✓")
    else:
        print(f"CRC mismatch! Data may be corrupted.")
    
    with open(output_path, 'wb') as f:
        f.write(payload)
    print(f"Decoded {len(payload)} bytes -> {output_path}")


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print("Usage: python visenc.py encode <input> <output.png>")
        print("       python visenc.py decode <input.png> <output>")
        sys.exit(1)
    
    cmd, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    
    if cmd == 'encode':
        with open(src, 'rb') as f:
            encode(f.read(), dst)
    elif cmd == 'decode':
        decode(src, dst)
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)