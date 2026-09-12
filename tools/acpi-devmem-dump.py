#!/usr/bin/env python3
# =============================================================================
# acpi-devmem-dump.py — 在"用设备树启动、内核未初始化 ACPI"的机器上，直接从
#                       /dev/mem 读出固件的 ACPI 表并做取证
#
# 适用场景
# --------
# gaokun3 这类机型用 DTB 启动，因此 Linux 侧既没有 /sys/firmware/acpi/，也没有
# /proc/kcore；ACPI 表虽然仍在内存里，但受 CONFIG_STRICT_DEVMEM 限制读不到：
#
#   PermissionError: [Errno 1] Operation not permitted
#
# ⚠️ **重要实测结论（2026-09，本机已验证）**：在 arm64 上给内核命令行加
# `iomem=relaxed` **并不能**解决这个问题。arm64 的 `devmem_is_allowed()` 对
# 落在 System RAM 里的地址**无条件返回 0**，而 `iomem=relaxed` 只放松
# `iomem_is_exclusive()` 那条判据；ACPI 表恰好位于 System RAM 内
# （本机 /proc/iomem 显示 `fff22000-3fffffff : System RAM` 内嵌
# `fff22000-ffffdfff : reserved`，RSDP 在 `0xffffd000`）。
# 实测加了该参数重启后仍然 EPERM。
#
# 因此本脚本真正可用的前提是**内核不带 CONFIG_STRICT_DEVMEM 编译**
# （`# CONFIG_STRICT_DEVMEM is not set` 时 drivers/char/mem.c 的
# `range_is_allowed()` 恒真）。路线见 docs/fingerprint.md §8.3：
# 自行编译一份关闭该选项的内核，作为独立启动项临时引导一次，用完即删。
#
# RSDP 的物理地址可以从 dmesg 拿到：
#
#   dmesg | grep 'efi: ACPI 2.0='
#   [    0.000000] efi: ACPI 2.0=0xffffd000 ...
#
# 本脚本只读内存，不写任何内存。
#
# 用法
# ----
#   sudo python3 acpi-devmem-dump.py --list
#   sudo python3 acpi-devmem-dump.py --find FTE7001 SPBA
#   sudo python3 acpi-devmem-dump.py --serial-bus        # 列出全部 I2C/SPI/UART 连接描述符
#   sudo python3 acpi-devmem-dump.py --rsdp 0xffffd000 --find FTE7001
#
# 为什么要专门找"串行总线连接描述符"
# ------------------------------------
# AML 是编译过的二进制，`_CRS` 里的 I2C/SPI/UART 不会以字符串形式出现，而是
# ACPI 规范定义的大项资源描述符（Large Resource Data Type）：
#
#   0x8C = I2C Serial Bus Connection
#   0x8D = SPI Serial Bus Connection
#   0x8E = UART Serial Bus Connection
#   0x8F = CSI-2 Serial Bus Connection
#
# 每个描述符紧跟 2 字节小端长度。把它们连同"向前最近的一个标识符"一起列出来，
# 就能直接回答"某个设备到底挂在 I2C 还是 SPI 上"。
#
# 许可证：GPL-2.0-only（与本项目一致）
# 项目主页：https://github.com/aoripus/easy-for-gaokun
# =============================================================================

import argparse
import binascii
import re
import struct
import sys

MAX_TABLE = 4 << 20          # 单表上限 4 MiB（防御性）
SERIAL_BUS = {0x8C: "I2C", 0x8D: "SPI", 0x8E: "UART", 0x8F: "CSI-2"}


def rd(f, phys, n):
    f.seek(phys)
    return f.read(n)


def read_rsdp(f, phys):
    d = rd(f, phys, 64)
    if d[:8] != b"RSDP":
        raise RuntimeError("RSDP @0x%x 签名不对：%r" % (phys, d[:8]))
    length = struct.unpack_from("<I", d, 20)[0]
    rsdt = struct.unpack_from("<I", d, 16)[0]
    xsdt = struct.unpack_from("<Q", d, 24)[0] if length >= 36 else 0
    return {"revision": d[15], "oemid": d[9:15], "rsdt": rsdt, "xsdt": xsdt, "length": length}


def read_tables(f, rsdp):
    """返回 [(物理地址, 签名, 整表字节)]。"""
    root_phys = rsdp["xsdt"] or rsdp["rsdt"]
    wide = bool(rsdp["xsdt"])
    hdr = rd(f, root_phys, 36)
    sig, tlen = hdr[:4], struct.unpack_from("<I", hdr, 4)[0]
    if tlen < 36 or tlen > MAX_TABLE:
        raise RuntimeError("根表长度异常：%d" % tlen)
    body = rd(f, root_phys + 36, tlen - 36)
    esz = 8 if wide else 4
    fmt = "<Q" if wide else "<I"
    out = []
    for i in range(len(body) // esz):
        addr = struct.unpack_from(fmt, body, i * esz)[0]
        if not addr:
            continue
        t = rd(f, addr, 36)
        if len(t) < 36:
            continue
        s = t[:4]
        l = struct.unpack_from("<I", t, 4)[0]
        if l < 36 or l > MAX_TABLE:
            continue
        full = t + rd(f, addr + 36, l - 36)
        out.append((addr, s.decode("latin1"), full))
    return out


def enclosing_name(data, offset, back=6000):
    """向前找最近的、像 ACPI 名字的 ASCII 串（Device/Name 对象名）。"""
    start = max(0, offset - back)
    chunk = data[start:offset]
    runs = re.findall(rb"[A-Za-z_][A-Za-z0-9_]{3,}", chunk)
    for r in reversed(runs):
        return r.decode("latin1")
    return "?"


def cmd_list(tables):
    print("%-14s %-6s %-10s %s" % ("物理地址", "签名", "长度", "OEM / TableID"))
    print("-" * 80)
    for addr, sig, data in tables:
        print("0x%010x %-6s %-10d %r / %r" % (addr, sig, len(data), data[10:16], data[16:24]))


def cmd_find(tables, needles, context=1800):
    found = False
    for addr, sig, data in tables:
        for nd in needles:
            b = nd.encode()
            start = 0
            while True:
                i = data.find(b, start)
                if i < 0:
                    break
                found = True
                print("=" * 90)
                print("%s @ 表 %s(0x%x) 偏移 0x%x，所在范围标识符：%s"
                      % (nd, sig, addr, i, enclosing_name(data, i)))
                lo, hi = max(0, i - 64), min(len(data), i + context)
                # 十六进制 + 可打印字符并排输出
                for off in range(lo, hi, 16):
                    row = data[off:off + 16]
                    print("  0x%06x  %-47s  %s" % (off, binascii.hexlify(row, " ").decode(),
                                                   "".join(chr(c) if 32 <= c < 127 else "." for c in row)))
                start = i + 1
    if not found:
        print("未找到：%s" % ", ".join(needles))
        return 1
    return 0


def cmd_serial_bus(tables):
    """列出所有 I2C/SPI/UART 串行总线连接描述符及其所属设备。"""
    total = 0
    for addr, sig, data in tables:
        if sig not in ("DSDT", "SSDT"):
            continue
        for off in range(len(data) - 3):
            tag = data[off]
            if tag not in SERIAL_BUS:
                continue
            ln = struct.unpack_from("<H", data, off + 1)[0]
            # 描述符至少要有 类型(1)+长度(2)+RevId(1)+ResIdx(1)+Type(1)+Flags(1)+
            # TypeSpecific(1)+... 这类字段，取 12 作为宽松下界
            if ln < 12 or ln > 256 or off + 3 + ln > len(data):
                continue
            total += 1
            payload = data[off + 3:off + 3 + ln]
            name = enclosing_name(data, off)
            extra = ""
            if len(payload) >= 12:
                # SerialBus 描述符（ACPI 6.x）字段布局：
                #   RevId(1) ResIdx(1) Type(1) Flags(1) TypeSpecificFlags(1)
                #   TypeSpecificRevision(1) TypeSpecificData(2) [I2C/SPI: TypeSpecificData]
                #   TypeDataLength(2) ...
                extra = "  rev=%d type=%d flags=0x%02x" % (payload[0], payload[2], payload[3])
            print("0x%06x  %-5s len=%-4d 所属范围=%-16s%s" % (off, SERIAL_BUS[tag], ln, name, extra))
    print("\n合计 %d 个串行总线连接描述符" % total)
    return 0


def main():
    ap = argparse.ArgumentParser(description="从 /dev/mem 读 ACPI 表做取证（需要 iomem=relaxed）")
    ap.add_argument("--mem", default="/dev/mem")
    ap.add_argument("--rsdp", default="0xffffd000",
                    help="RSDP 物理地址，取自 `dmesg | grep 'efi: ACPI 2.0='`（默认 0xffffd000）")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--list", action="store_true", help="列出全部 ACPI 表")
    g.add_argument("--find", nargs="+", metavar="STR", help="搜索字符串并打印上下文十六进制")
    g.add_argument("--serial-bus", action="store_true",
                   help="列出全部 I2C/SPI/UART 连接描述符及其所属设备")
    args = ap.parse_args()

    try:
        f = open(args.mem, "rb", buffering=0)
    except Exception as e:
        sys.exit("打开 %s 失败：%s\n（若为 Permission denied，需要给内核命令行加 iomem=relaxed 后重启）"
                 % (args.mem, e))

    try:
        rsdp = read_rsdp(f, int(args.rsdp, 0))
    except Exception as e:
        sys.exit("读取 RSDP 失败：%s" % e)
    print("RSDP OEM=%r revision=%d XSDT=0x%x RSDT=0x%x" %
          (rsdp["oemid"], rsdp["revision"], rsdp["xsdt"], rsdp["rsdt"]))

    tables = read_tables(f, rsdp)
    print("读到 %d 张表\n" % len(tables))

    if args.list:
        return cmd_list(tables)
    if args.serial_bus:
        return cmd_serial_bus(tables)
    return cmd_find(tables, args.find)


if __name__ == "__main__":
    sys.exit(main())
