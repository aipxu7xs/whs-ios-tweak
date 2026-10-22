#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dump_objc.py — 从 iOS Mach-O 抽取 ObjC 类名(__objc_classname)与方法名(__objc_methname)

不依赖 LIEF / class-dump：Mach-O 的 __objc_classname / __objc_methname 段是纯 C 字符串，
按段偏移读取、按 \\0 切分即可，稳定且跨平台（Windows 可跑）。

兼容：脱壳 IPA / 胖二进制(arm64 切片) / 瘦二进制。

用法：
  python dump_objc.py Xiaohongshu.ipa
  python dump_objc.py Xiaohongshu.ipa --kw feed,note,download,ad,comment,tab,profile,update
  python dump_objc.py path/to/discover          # 直接给 Mach-O
"""
import sys, os, re, zipfile, plistlib


def get_binary_bytes(path):
    """返回 (bytes, 来源说明)。支持 .ipa / 胖 / 瘦。"""
    if path.lower().endswith(".ipa"):
        out_dir = os.path.join(os.path.dirname(path) or ".", "extracted")
        os.makedirs(out_dir, exist_ok=True)
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            plist = next((n for n in names if n.endswith(".app/Info.plist")), None)
            if not plist:
                raise SystemExit("IPA 内找不到 Info.plist")
            exe = plistlib.loads(z.read(plist)).get("CFBundleExecutable")
            app_dir = os.path.dirname(plist)
            data = z.read(f"{app_dir}/{exe}")
            target = os.path.join(out_dir, exe)
            with open(target, "wb") as f:
                f.write(data)
            print(f"[*] 解包主二进制 -> {target} ({len(data)//1024//1024} MB)")
            return data, target
    with open(path, "rb") as f:
        return f.read(), path


def pick_arm64_slice(data):
    """若是胖二进制，返回 arm64 切片的 (offset,size)；否则返回 (0, len)。"""
    magic = data[:4]
    fat_magics = (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
    if magic not in fat_magics:
        return 0, len(data)
    end = ">"  # 胖头固定大端
    nfat = struct.unpack(end + "I", data[4:8])[0]
    if magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):  # 64-bit fat
        off = 8
        for _ in range(nfat):
            cp, sub, o, s, align, reserved = struct.unpack(end + "iiQQII", data[off:off + 32])
            off += 32
            if (cp & 0x01000000) and not (sub & 0x80000000):  # arm64 非 arm64e 优先
                return o, s
        # 否则退而求其次：第一个 arm64（含 arm64e）
        off = 8
        for _ in range(nfat):
            cp, sub, o, s, align, reserved = struct.unpack(end + "iiQQII", data[off:off + 32])
            off += 32
            if cp & 0x01000000:
                return o, s
    else:  # 32-bit fat
        off = 8
        for _ in range(nfat):
            cp, sub, o, s, align = struct.unpack(end + "iiII", data[off:off + 20])
            off += 20
            if cp & 0x01000000:
                return o, s
    return 0, len(data)


import struct

LC_SEGMENT_64 = 0x19
LC_SEGMENT = 0x1

OBJ_SECTIONS = ("__objc_methname", "__objc_classname", "__objc_methtype")


def parse_sections(data):
    """返回 [(sectname, segname, fileoff, size, vmaddr)]。"""
    o, s = pick_arm64_slice(data)
    blob = data[o:o + s]
    magic = blob[:4]
    if magic in (b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"):
        little = magic == b"\xcf\xfa\xed\xfe"
    elif magic in (b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe"):
        little = magic == b"\xce\xfa\xed\xfe"
    else:
        raise SystemExit(f"未知 Mach-O magic: {magic.hex()}")
    end = "<" if little else ">"
    is64 = magic in (b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe")
    off = 32 if is64 else 28
    ncmds = struct.unpack(end + "I", blob[16:20])[0]
    sections = []
    p = off
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack(end + "II", blob[p:p + 8])
        if cmd in (LC_SEGMENT_64, LC_SEGMENT):
            segname = blob[p + 8:p + 24].split(b"\x00")[0].decode("latin1", "replace")
            if cmd == LC_SEGMENT_64:
                nsects = struct.unpack(end + "I", blob[p + 64:p + 68])[0]
                sect_off = p + 72
                step = 80
            else:
                nsects = struct.unpack(end + "I", blob[p + 48:p + 52])[0]
                sect_off = p + 56
                step = 68
            for j in range(nsects):
                sp = sect_off + j * step
                if sp + step > len(blob):
                    break
                sectname = blob[sp:sp + 16].split(b"\x00")[0].decode("latin1", "replace")
                seg2 = blob[sp + 16:sp + 32].split(b"\x00")[0].decode("latin1", "replace")
                if is64:
                    size = struct.unpack(end + "Q", blob[sp + 40:sp + 48])[0]
                    soff = struct.unpack(end + "I", blob[sp + 48:sp + 52])[0]
                    addr = struct.unpack(end + "Q", blob[sp + 32:sp + 40])[0]
                else:
                    size = struct.unpack(end + "I", blob[sp + 36:sp + 40])[0]
                    soff = struct.unpack(end + "I", blob[sp + 40:sp + 44])[0]
                    addr = struct.unpack(end + "I", blob[sp + 32:sp + 36])[0]
                sections.append((sectname, seg2, soff, size, addr))
        p += cmdsize
    return sections


def split_strings(b):
    """按 \\0 切分 C 字符串，过滤掉空串与非 ASCII 为主的噪声。"""
    out = []
    for part in b.split(b"\x00"):
        if 2 <= len(part) <= 400:
            try:
                t = part.decode("utf-8")
            except Exception:
                continue
            if t.isprintable() and any(c.isalpha() for c in t):
                out.append(t)
    return out


def extract(data):
    sections = parse_sections(data)
    classnames, methodnames, typenames = set(), set(), set()
    for sectname, seg2, soff, size, addr in sections:
        if sectname == "__objc_classname":
            classnames.update(split_strings(data[soff:soff + size]))
        elif sectname == "__objc_methname":
            methodnames.update(split_strings(data[soff:soff + size]))
        elif sectname == "__objc_methtype":
            typenames.update(split_strings(data[soff:soff + size]))
    return sorted(classnames), sorted(methodnames), sorted(typenames)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(1)
    path = sys.argv[1]
    kws = []
    if "--kw" in sys.argv:
        kws = [k for k in sys.argv[sys.argv.index("--kw") + 1].split(",") if k]

    data, src = get_binary_bytes(path)
    print(f"[*] 来源: {src}")
    cn, mn, tn = extract(data)
    print(f"[*] 类名 {len(cn)} / 方法名(selector) {len(mn)} / 类型编码 {len(tn)}")

    out_dir = os.path.dirname(src) or "."
    with open(os.path.join(out_dir, "objc_classnames.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(cn) + "\n")
    with open(os.path.join(out_dir, "objc_methodnames.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(mn) + "\n")

    if kws:
        pat = re.compile("|".join(re.escape(k) for k in kws), re.I)
        m_cn = [c for c in cn if pat.search(c)]
        m_mn = [m for m in mn if pat.search(m)]
        with open(os.path.join(out_dir, "objc_match.txt"), "w", encoding="utf-8") as f:
            f.write(f"# 关键词: {', '.join(kws)}\n")
            f.write(f"# 命中类名 {len(m_cn)} / 方法名 {len(m_mn)}\n\n")
            f.write("==== 候选类名 ====\n")
            f.write("\n".join(m_cn) + "\n\n")
            f.write("==== 候选方法名(selector) ====\n")
            f.write("\n".join(m_mn) + "\n")
        print(f"[*] 命中 类名 {len(m_cn)} / 方法名 {len(m_mn)} -> {os.path.join(out_dir,'objc_match.txt')}")

    print(f"[*] 全量类名 -> {os.path.join(out_dir,'objc_classnames.txt')}")
    print(f"[*] 全量方法名 -> {os.path.join(out_dir,'objc_methodnames.txt')}")


if __name__ == "__main__":
    main()
