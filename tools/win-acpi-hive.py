#!/usr/bin/env python3
# =============================================================================
# win-acpi-hive.py — 从离线的 Windows SYSTEM 注册表 hive 中读出「本机实际枚举到的
#                    ACPI 设备树与资源分配」
#
# 为什么需要它
# ------------
# gaokun3 用设备树（DTB）启动，内核不初始化 ACPI，因此 Linux 侧既没有
# /sys/firmware/acpi/，也没有 /proc/kcore，无法直接读 DSDT。而 Windows 装在同一块
# 硬盘上、且确实启动过 —— 它的 SYSTEM hive 里
#   HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\<HID>\<实例>
# 记录的是**这台机器真正枚举过的** ACPI 设备（不是驱动包里"可能支持"的设备），
# 并且 `LogConf\BootConfig` 保存了 Windows 为每个设备分配的资源
# （CM_RESOURCE_LIST，含中断与 CM_RESOURCE_CONNECTION 连接描述符）。
#
# 于是不必重启进 Windows、也不必改内核 cmdline 加 iomem=relaxed：
# 在 Linux 里只读挂载 NTFS 分区、拷出 SYSTEM 即可离线解析。
#
# 实测示例（GK-W7X / gaokun3，2026-09）
# -----------------------------------
#   python3 win-acpi-hive.py SYSTEM --tree
#   python3 win-acpi-hive.py SYSTEM --resources FTE7001
#   python3 win-acpi-hive.py SYSTEM --connections
#
# 依赖：python3-hivex（Ubuntu: sudo apt-get install python3-hivex）
#
# 关于 CM_RESOURCE_CONNECTION 的字节布局（本项目实测校准）
# ------------------------------------------------------
# 资源描述符固定为 4 + 16 = 20 字节：Type(1) ShareDisposition(1) Flags(2) + union(16)。
# 连接描述符（Type = 0x84）的 union 前两字节是 Class 与 Type：
#
#   Class: 0x01 = GPIO      0x02 = SERIAL（SPB）
#   Type : GPIO   0x01 = IO         0x02 = INT
#          SERIAL 0x01 = I2C        0x02 = SPI        0x03 = UART
#
# 判据来自同一台机器上的已知设备（见 --connections）：
#   * HIMX0002（Himax 触屏，Linux 侧确认走 SPI）→ 02 02 = SERIAL/SPI
#   * QCOM066B（Bluetooth UART Transport）      → 02 03 = SERIAL/UART
#   * QCOM0696 / SDC / GPU / ISP（PCIe、SD、GPIO 中断类）→ 01 02 = GPIO/INT
# 因此 `02 02` 必为 SPI、`01 02` 必为 GPIO 中断，二者不会混淆。
#
# 许可证：GPL-2.0-only（与本项目一致）
# 项目主页：https://github.com/aoripus/easy-for-gaokun
# =============================================================================

import argparse
import binascii
import struct
import sys

try:
    import hivex
except ImportError:  # pragma: no cover
    sys.exit("缺少依赖：python3-hivex（sudo apt-get install python3-hivex）")

# DEVPKEY_Device_Parent：{a45c254e-df1c-4efd-8020-67d146a850e0}, 37
PARENT_GUID = "a45c254e-df1c-4efd-8020-67d146a850e0"
PARENT_PID = 0x25

CONN_CLASS = {0x01: "GPIO", 0x02: "SERIAL", 0x03: "FUNCTION"}
CONN_TYPE = {
    (0x01, 0x01): "GPIO_IO",
    (0x01, 0x02): "GPIO_INT",
    (0x02, 0x01): "I2C",
    (0x02, 0x02): "SPI",
    (0x02, 0x03): "UART",
}
RES_TYPE = {
    0x00: "Null", 0x01: "Port", 0x02: "Interrupt", 0x03: "Memory",
    0x04: "Dma", 0x05: "DeviceSpecific", 0x06: "BusNumber",
    0x80: "ConfigData", 0x81: "DevicePrivate", 0x82: "PcCardConfig",
    0x83: "MfCardConfig", 0x84: "Connection",
}

DESC_SIZE = 20  # 4 字节头 + 16 字节 union，已由本机多个设备交叉验证


class Hive:
    def __init__(self, path):
        self.h = hivex.Hivex(path)
        self.root = self.h.root()

    def children(self, node):
        return {self.h.node_name(c): c for c in (self.h.node_children(node) or [])}

    def find(self, path, start=None):
        node = start if start is not None else self.root
        for part in path.strip("\\").split("\\"):
            kid = self.children(node).get(part)
            if kid is None:
                return None
            node = kid
        return node

    def value(self, node, name):
        """返回 (类型, 原始字节) 或 None。"""
        if node is None:
            return None
        for v in (self.h.node_values(node) or []):
            if self.h.value_key(v) == name:
                return self.h.value_value(v)
        return None

    def string(self, node, name):
        got = self.value(node, name)
        if not got:
            return None
        _, data = got
        try:
            return data.decode("utf-16-le", "replace").rstrip("\x00").replace("\x00", "|")
        except Exception:
            return repr(data)

    def property(self, node, guid, pid):
        """Enum\\...\\Properties\\{guid}\\XXXX 形式的设备属性（可能是 0xFFFF00xx 前缀的原始类型）。"""
        props = self.find("Properties", node)
        if props is None:
            return None
        g = self.children(props).get("{" + guid + "}")
        if g is None:
            return None
        k = self.children(g).get("%04X" % pid)
        if k is None:
            return None
        vals = self.h.node_values(k) or []
        if not vals:
            return None
        _, data = self.h.value_value(vals[0])
        # 属性键用小端 32 位类型码，0xFFFF00xx 表示"取自 INF 的原始类型"
        if len(data) >= 4 and data[2:4] == b"\x00\x00":
            data = data[4:]
        if len(data) >= 2 and data[1:2] == b"\x00":
            return data.decode("utf-16-le", "replace").rstrip("\x00")
        if len(data) == 4:
            return "0x%08x" % struct.unpack("<I", data)[0]
        return binascii.hexlify(data).decode()


def iter_acpi(hv):
    """生成 (ACPI ID, 实例, 实例节点)。"""
    enum = hv.find(r"ControlSet001\Enum\ACPI")
    if enum is None:
        sys.exit("hive 中没有 ControlSet001\\Enum\\ACPI")
    for hid, hidnode in sorted(hv.children(enum).items()):
        for inst, instnode in sorted(hv.children(hidnode).items()):
            yield hid, inst, instnode


def dev_desc(hv, node):
    s = hv.string(node, "DeviceDesc") or ""
    return s.split(";")[-1]


def parse_cm_resource_list(data, indent="      "):
    """CM_RESOURCE_LIST：4+4+4 头 + Version/Revision(4) + Count(4)，随后 20 字节描述符。"""
    if len(data) < 20:
        return
    count = struct.unpack_from("<I", data, 0)[0]
    iface, bus = struct.unpack_from("<II", data, 4)
    ver, rev = struct.unpack_from("<HH", data, 12)
    n = struct.unpack_from("<I", data, 16)[0]
    print("%sCM_RESOURCE_LIST count=%d InterfaceType=%d BusNumber=%d Version=%d.%d 描述符=%d"
          % (indent, count, iface, bus, ver, rev, n))
    off = 20
    for i in range(n):
        if off + DESC_SIZE > len(data):
            print("%s  !! 数据截断（第 %d 个描述符）" % (indent, i))
            return
        ty, share, flags = struct.unpack_from("<BBH", data, off)
        union = data[off + 4:off + DESC_SIZE]
        print("%s  [%d] Type=0x%02x(%s) ShareDisposition=%d Flags=0x%04x"
              % (indent, i, ty, RES_TYPE.get(ty, "?"), share, flags))
        if ty == 0x02:
            lvl, vec, aff = struct.unpack_from("<IIQ", union, 0)
            gpio = "（≥0x8000 ⇒ GPIO 触发）" if lvl >= 0x8000 else ""
            print("%s      Level=%d(0x%x) Vector=%d(0x%x) Affinity=0x%x %s"
                  % (indent, lvl, lvl, vec, vec, aff, gpio))
        elif ty == 0x84:
            cls, ctype = union[0], union[1]
            id1, id2 = struct.unpack_from("<II", union, 4)
            print("%s      Connection: Class=0x%02x(%s) Type=0x%02x(%s) Id1=%d Id2=%d"
                  % (indent, cls, CONN_CLASS.get(cls, "?"), ctype,
                     CONN_TYPE.get((cls, ctype), "?"), id1, id2))
            print("%s      raw union: %s" % (indent, binascii.hexlify(union, " ").decode()))
        else:
            print("%s      raw union: %s" % (indent, binascii.hexlify(union, " ").decode()))
        off += DESC_SIZE


def cmd_tree(hv):
    print("%-26s %-50s %s" % ("ACPI ID\\实例", "DeviceDesc", "Parent"))
    print("-" * 130)
    for hid, inst, node in iter_acpi(hv):
        parent = hv.property(node, PARENT_GUID, PARENT_PID) or "(根)"
        print("%-26s %-50s %s" % (hid + "\\" + inst, dev_desc(hv, node)[:50], parent))


def cmd_resources(hv, ids):
    hits = 0
    for hid, inst, node in iter_acpi(hv):
        if hid.upper() not in [i.upper() for i in ids]:
            continue
        hits += 1
        print("=" * 100)
        print("%s\\%s  ->  %s" % (hid, inst, dev_desc(hv, node)))
        print("  父设备: %s" % (hv.property(node, PARENT_GUID, PARENT_PID),))
        for key in ("HardwareID", "CompatibleIDs", "Service", "Driver"):
            v = hv.string(node, key)
            if v:
                print("  %-14s %s" % (key + ":", v))
        logconf = hv.find("LogConf", node)
        if logconf is None:
            print("  （没有 LogConf：该设备未被分配任何资源）")
            continue
        for v in (hv.h.node_values(logconf) or []):
            name = hv.h.value_key(v)
            _, data = hv.h.value_value(v)
            print("\n  --- %s（%d 字节）---" % (name, len(data)))
            if name.startswith("BasicConfig"):
                print("      （需求列表 IO_RESOURCE_REQUIREMENTS_LIST，此处只列 BootConfig 分配结果）")
                continue
            print("      hex: " + binascii.hexlify(data, " ").decode())
            parse_cm_resource_list(data)
    if not hits:
        print("hive 中没有匹配的 ACPI ID：%s" % ", ".join(ids))
        return 1
    return 0


def cmd_connections(hv):
    """扫描全部 ACPI 设备的连接描述符 —— 用已知设备反推 Class/Type 语义，并据此判定目标设备的总线。"""
    rows = []
    for hid, _inst, node in iter_acpi(hv):
        logconf = hv.find("LogConf", node)
        if logconf is None:
            continue
        data = hv.value(logconf, "BootConfig")
        if not data:
            continue
        _, blob = data
        if len(blob) < 20:
            continue
        n = struct.unpack_from("<I", blob, 16)[0]
        off = 20
        for _ in range(n):
            if off + DESC_SIZE > len(blob):
                break
            if blob[off] == 0x84:
                union = blob[off + 4:off + DESC_SIZE]
                cls, ctype = union[0], union[1]
                id1 = struct.unpack_from("<I", union, 4)[0]
                rows.append((CONN_TYPE.get((cls, ctype), "?"), hid, dev_desc(hv, node), cls, ctype, id1))
            off += DESC_SIZE
    print("%-10s %-14s %-44s %-6s %-6s %s" % ("连接类型", "ACPI ID", "DeviceDesc", "Class", "Type", "Id1"))
    print("-" * 110)
    for r in sorted(rows):
        print("%-10s %-14s %-44s 0x%02x   0x%02x   %d" % (r[0], r[1], r[2][:44], r[3], r[4], r[5]))
    from collections import Counter
    print("\nClass/Type 分布：")
    for k, v in sorted(Counter((r[3], r[4]) for r in rows).items()):
        print("   0x%02x/0x%02x (%s) -> %d 个设备"
              % (k[0], k[1], CONN_TYPE.get((k[0], k[1]), "?"), v))
    return 0


def cmd_find(hv, needles):
    """在 hive 中做 ASCII/UTF-16 关键字定位（用于确认某个硬件 ID 是否真的枚举过）。"""
    for needle in needles:
        found = []
        for hid, inst, node in iter_acpi(hv):
            if needle.lower() in (hid + "\\" + inst).lower():
                found.append("ACPI\\%s\\%s -> %s" % (hid, inst, dev_desc(hv, node)))
        print("%-14s 在 Enum\\ACPI 下的实例：%d" % (needle, len(found)))
        for f in found:
            print("    " + f)
        # 提示：驱动包里的 INF 出现某个 ID 并不代表本机存在该设备
        print("    (提示) 若要判断'驱动包里是否含 ICD'，用 grep -c '%s' 直接扫 hive 文件即可；"
              % needle)
        print("           本命令统计的是**枚举实例**，这才是'本机真的有这颗芯片'的证据。")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="离线解析 Windows SYSTEM hive，读出本机实际枚举的 ACPI 设备树与资源")
    ap.add_argument("hive", help="SYSTEM hive 文件（从 Windows/System32/config/SYSTEM 拷出）")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--tree", action="store_true", help="列出全部 ACPI 设备及其父设备")
    g.add_argument("--resources", nargs="+", metavar="ACPI_ID",
                   help="打印指定 ACPI ID（如 FTE7001）的资源分配")
    g.add_argument("--connections", action="store_true",
                   help="扫描所有连接描述符并统计 Class/Type 分布")
    g.add_argument("--find", nargs="+", metavar="PATTERN", help="查找某个 ACPI ID 是否被枚举")
    args = ap.parse_args()

    hv = Hive(args.hive)
    if args.tree:
        cmd_tree(hv)
        return 0
    if args.connections:
        return cmd_connections(hv)
    if args.find:
        return cmd_find(hv, args.find)
    return cmd_resources(hv, args.resources)


if __name__ == "__main__":
    sys.exit(main())
