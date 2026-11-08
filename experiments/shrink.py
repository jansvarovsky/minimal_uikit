#!/usr/bin/env python3
"""Shrink a linked Mach-O by rewriting its file layout.

usage: shrink.py IN OUT [--overlap]

Default: make __DATA_CONST zero-fill and pull __LINKEDIT down over the freed bytes.
--overlap: also drop __TEXT's trailing __pad section from the file, put the
__LINKEDIT payload right after the code, and map __LINKEDIT from file offset 0.

Input must be linked with bind opcodes (-no_fixup_chains) and be unsigned,
so that the segment's on-disk bytes are all zero and nothing needs them.
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_DYLD_INFO_ONLY = 0x80000022
LC_LINKEDIT_DATA = {0x26, 0x29, 0x80000033, 0x80000034}  # starts, in-code, trie, chains


def shift_linkedit_offsets(b, cmds, delta):
    def shift(pos):
        v = struct.unpack_from("<I", b, pos)[0]
        if v:
            struct.pack_into("<I", b, pos, v - delta)

    for cmd, o in cmds:
        if cmd == LC_SYMTAB:
            shift(o + 8), shift(o + 16)
        elif cmd == LC_DYSYMTAB:
            for field in (32, 40, 48, 56, 64, 72):
                shift(o + field)
        elif cmd == LC_DYLD_INFO_ONLY:
            for field in (8, 16, 24, 32, 40):
                shift(o + field)
        elif cmd in LC_LINKEDIT_DATA:
            shift(o + 8)


def main(src, dst, overlap=False):
    b = bytearray(open(src, "rb").read())
    ncmds = struct.unpack_from("<I", b, 16)[0]
    segs = {}
    cmds = []
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", b, off)
        cmds.append((cmd, off))
        if cmd == LC_SEGMENT_64:
            segs[bytes(b[off + 8:off + 24]).rstrip(b"\0").decode()] = off
        off += size

    if set(segs) != {"__PAGEZERO", "__TEXT", "__DATA_CONST", "__LINKEDIT"}:
        sys.exit(f"unexpected segments {sorted(segs)}; refusing to patch")
    d = segs["__DATA_CONST"]
    fileoff, filesize = struct.unpack_from("<QQ", b, d + 40)
    if any(b[fileoff:fileoff + filesize]):
        sys.exit("__DATA_CONST has non-zero file content; refusing to drop it")

    struct.pack_into("<QQ", b, d + 40, 0, 0)
    for i in range(struct.unpack_from("<I", b, d + 64)[0]):
        struct.pack_into("<I", b, d + 72 + i * 80 + 48, 0)  # section.offset

    le = segs["__LINKEDIT"]
    struct.pack_into("<Q", b, le + 40, struct.unpack_from("<Q", b, le + 40)[0] - filesize)
    shift_linkedit_offsets(b, cmds, filesize)
    del b[fileoff:fileoff + filesize]

    if overlap:
        t = segs["__TEXT"]
        text_filesize = struct.unpack_from("<Q", b, t + 48)[0]
        end = None
        for i in range(struct.unpack_from("<I", b, t + 64)[0]):
            s = t + 72 + i * 80
            if bytes(b[s:s + 16]).rstrip(b"\0") == b"__pad":
                end = struct.unpack_from("<I", b, s + 48)[0]
                if any(b[end:text_filesize]):
                    sys.exit("__pad is not all zero; refusing to drop it")
                struct.pack_into("<Q", b, s + 40, 0)  # size
                struct.pack_into("<I", b, s + 48, 0)  # offset
        if end is None:
            sys.exit("no __TEXT,__pad section; link with one for --overlap")
        end = (end + 7) & ~7
        payload = bytes(b[text_filesize:])
        shift_linkedit_offsets(b, cmds, text_filesize - end)
        struct.pack_into("<Q", b, t + 48, end)  # __TEXT filesize
        struct.pack_into("<QQ", b, le + 40, 0, end + len(payload))  # __LINKEDIT
        b = b[:end] + payload

    open(dst, "wb").write(b)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], "--overlap" in sys.argv[3:])
