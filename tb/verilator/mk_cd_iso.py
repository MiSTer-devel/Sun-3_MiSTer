#!/usr/bin/env python3
"""A small test CD for tb_emu's CD-ROM (sr0, SCSI ID 6).

    python3 mk_cd_iso.py <dir>        writes <dir>/cdtest.iso

An ISO 9660 image made by genisoimage (or mkisofs) with a Sun disk label in
its system area, as Sun's install CDs have: partition 0 (a) is the whole
ISO 9660 file system, partition 1 (b) a boot image (-sparc-boot).  The PROM
boots a CD with its disk driver, in 512-byte blocks: it reads the label
from block 0, then 8 KiB from the partition's block 1 into memory (Rev
3.0.1: READ(6) of 16 blocks) and jumps there, so

    b sd(0,30,1)      Rev 3.0.1 (unit = target << 3)
    b sd(0,18,1)      Rev 1.9   (unit = target << 2)

runs the boot block, which prints a line through the PROM's putchar
(romvec + 0x18) and returns to the monitor (exitToMon, romvec + 0xC4).
"""
import os
import shutil
import struct
import subprocess
import sys

MSG = b"\r\nsr0: the CD's boot block is running\r\n"

# 68020 code, position independent, run at 0x4000:
#   lea     msg(pc),a2
# 1:moveq   #0,d0
#   move.b  (a2)+,d0
#   beq.s   2f
#   move.l  d0,-(sp)
#   movea.l 0x0FEF0018,a0        romvec putChar
#   jsr     (a0)
#   addq.l  #4,sp
#   bra.s   1b
# 2:movea.l 0x0FEF00C4,a0        romvec exitToMon
#   jsr     (a0)
#   bra.s   .
CODE = bytes.fromhex(
    "45FA0020"        # 00 lea (0x22,pc),a2: msg at 0x22
    "7000"            # 04 moveq #0,d0
    "101A"            # 06 move.b (a2)+,d0
    "670E"            # 08 beq.s 0x18
    "2F00"            # 0a move.l d0,-(sp)
    "20790FEF0018"    # 0c movea.l (0x0FEF0018).l,a0
    "4E90"            # 12 jsr (a0)
    "588F"            # 14 addq.l #4,sp
    "60EC"            # 16 bra.s 0x04
    "20790FEF00C4"    # 18 movea.l (0x0FEF00C4).l,a0
    "4E90"            # 1e jsr (a0)
    "60FE"            # 20 bra.s 0x20
)
assert len(CODE) == 0x22


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    tool = shutil.which("genisoimage") or shutil.which("mkisofs")
    if not tool:
        sys.exit("mk_cd_iso: needs genisoimage or mkisofs")
    root = os.path.join(out, "cdtest_root")
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "README"), "wb") as f:
        f.write(b"A test CD for the Sun-3/60 MiSTer core's sr0.\n")
    boot = bytearray(8192)                       # block 0 unused, the code at block 1
    boot[512:512 + len(CODE) + len(MSG) + 1] = CODE + MSG + b"\0"
    bootimg = os.path.join(out, "cdtest_boot.img")
    with open(bootimg, "wb") as f:
        f.write(boot)
    iso = os.path.join(out, "cdtest.iso")
    subprocess.run([tool, "-quiet", "-r", "-V", "SUN3_CDTEST", "-sparc-label", "Sun-3 MiSTer test CD",
                    "-B", bootimg, "-o", iso, root], check=True)
    # Check the label as the PROM will: magic 0xDABE at 508, the XOR of all
    # 256 words zero, and partition 1's start (cylinder * heads * sectors).
    with open(iso, "rb") as f:
        lab = f.read(512)
    words = struct.unpack(">256H", lab)
    x = 0
    for w in words:
        x ^= w
    nhead, nsect = struct.unpack(">HH", lab[436:440])
    cyl, nblk = struct.unpack(">II", lab[444 + 8:444 + 16])
    if words[254] != 0xDABE or x != 0:
        sys.exit("mk_cd_iso: no Sun label in the image")
    start = cyl * nhead * nsect
    with open(iso, "rb") as f:
        f.seek(start * 512 + 512)
        if f.read(len(CODE)) != CODE:
            sys.exit("mk_cd_iso: the boot image is not where partition 1 says")
    print(f"{iso}: {os.path.getsize(iso)} bytes, Sun label: {nhead} heads, {nsect} sectors; "
          f"partition 1 at block {start}, {nblk} blocks")


if __name__ == "__main__":
    main()
