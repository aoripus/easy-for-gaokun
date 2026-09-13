#!/usr/bin/env python3
# =============================================================================
# gk-touch-bench.py —— 触屏通路量化对比（报点率 / 帧间隔 / 抖动 / IRQ 效率）
#
# 目的：用**可复现的数字**回答"i2c-hid 与 spi6 哪条通路的性能更好、延迟更低"，
#       而不是靠手感。两条通路的差别只在设备树（触屏节点与引脚模式），
#       因此测量方法、滑动动作、时长保持完全一致即可横向比较。
#
# 用法（在平板本地执行，需 root 读 /dev/input 与 /proc/interrupts）：
#   sudo ./gk-touch-bench.py --label spi6 --seconds 10
#   sudo ./gk-touch-bench.py --label i2c-hid --seconds 10 --device /dev/input/event4
#   sudo ./gk-touch-bench.py --list          # 只列出输入设备与触屏 IRQ
#
# 测量项：
#   * 帧率（SYN_REPORT/s）与总帧数
#   * 帧间隔分布：中位数 / p95 / p99 / 最大值（越小越跟手，抖动越小越稳）
#   * 长间隔（> 2× 中位数）计数 —— 卡顿感来源
#   * ABS/KEY 事件量与 每帧触点事件数（多指并发能力）
#   * 滑动窗口内触屏 IRQ 增量与其"每帧 IRQ 数"（批处理效率）
#   * 测量期间本机 CPU 占用（/proc/stat 差值）
#
# 输出：人类可读表格 + 末尾一行 JSON（便于跨版本归档与回归对比）
# =============================================================================
import argparse
import json
import os
import struct
import sys
import time

INPUT_EVENT_FMT = "llHHi"          # aarch64: timeval(tv_sec,tv_usec) + type + code + value
INPUT_EVENT_SIZE = struct.calcsize(INPUT_EVENT_FMT)   # 应为 24
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
BTN_TOUCH = 0x14A


def list_devices():
    print("== /proc/bus/input/devices ==")
    with open("/proc/bus/input/devices") as f:
        cur = {}
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if cur:
                    print(f"  {cur.get('Handlers','?'):24} {cur.get('Name','?')}")
                    cur = {}
                continue
            if line.startswith("N: Name="):
                cur["Name"] = line[8:].strip('"')
            elif line.startswith("H: Handlers="):
                cur["Handlers"] = line[12:]
    print("\n== 触屏相关 IRQ ==")
    with open("/proc/interrupts") as f:
        for line in f:
            if "himax" in line or "hx83121a" in line or "i2c" in line.lower() and "hid" in line:
                print("  " + " ".join(line.split()[:1] + line.split()[1:3]) + " ...")
            elif "himax" in line:
                print("  " + line.strip())


def touch_irq_lines():
    """返回与触屏相关的 /proc/interrupts 行（用于统计 IRQ 增量）"""
    out = []
    with open("/proc/interrupts") as f:
        for line in f:
            low = line.lower()
            if "himax" in low or "hx83121a" in low or "i2c_hid" in low or "i2c-hid" in low:
                out.append(line)
    return out


def sum_irqs():
    total = 0
    for line in touch_irq_lines():
        parts = line.split()
        for p in parts[1:]:
            if p.isdigit():
                total += int(p)
            else:
                break
    return total


def cpu_total():
    with open("/proc/stat") as f:
        fields = f.readline().split()[1:]
    return sum(int(x) for x in fields), int(fields[3])   # total, idle


def find_touch_device():
    """在 /proc/bus/input/devices 里找名字像触屏的设备，返回 (event 节点, 名字)"""
    cands = []
    with open("/proc/bus/input/devices") as f:
        cur = {}
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if cur:
                    cands.append(cur)
                    cur = {}
                continue
            if line.startswith("N: Name="):
                cur["Name"] = line[8:].strip('"')
            elif line.startswith("H: Handlers="):
                cur["Handlers"] = line[12:]
                cur["event"] = next((h for h in cur["Handlers"].split() if h.startswith("event")), None)
    if cands:
        cands = [c for c in cands if c.get("event")]
    kw = ("himax", "hx83121a", "touchscreen", "touch")
    hit = [c for c in cands if any(k in c["Name"].lower() for k in kw)]
    if hit:
        return "/dev/input/" + hit[0]["event"], hit[0]["Name"]
    return None, None


def percentile(sorted_vals, q):
    if not sorted_vals:
        return float("nan")
    idx = min(len(sorted_vals) - 1, int(round(q * (len(sorted_vals) - 1))))
    return sorted_vals[idx]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="touch")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--device", default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--json", default=None, help="把结果 JSON 追加写入该文件")
    ap.add_argument("--wait-timeout", type=float, default=0.0,
                    help="等待首次触摸的秒数；>0 时**以第一帧为计时起点**（推荐，A/B 对比更公平），0=立即计时")
    args = ap.parse_args()

    if args.list:
        list_devices()
        return 0

    if INPUT_EVENT_SIZE != 24:
        print(f"警告: struct input_event 大小为 {INPUT_EVENT_SIZE}（预期 24），字段解析可能不对", file=sys.stderr)

    dev = args.device
    name = "?"
    if not dev:
        dev, name = find_touch_device()
        if not dev:
            print("找不到触屏输入设备，请用 --list 查看后 --device 指定", file=sys.stderr)
            return 2
    print(f"[gk] 设备: {dev}  ({name})")
    print(f"[gk] 测量 {args.seconds:.1f} s —— 请**现在开始**在屏幕上持续匀速滑动（按住并来回划）")

    irq_before = sum_irqs()
    c_tot0, c_idle0 = cpu_total()

    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    frames = []          # 每帧的接收时刻
    frame_pts = []       # 每帧的触点事件数
    n_abs = n_key = n_syn = 0
    pending = 0
    t0 = None          # 计时起点 = 第一帧；两条通路因此测的是同一段有效动作
    wait_deadline = time.monotonic() + args.wait_timeout if args.wait_timeout > 0 else None
    if args.wait_timeout > 0:
        print("[gk] 等待你开始触摸（最多 %.0f 秒）..." % args.wait_timeout, flush=True)

    while True:
        now = time.monotonic()
        if t0 is None:
            if wait_deadline is not None and now > wait_deadline:
                print("[gk] 等待首次触摸超时", flush=True)
                break
        elif now >= t0 + args.seconds:
            break
        try:
            data = os.read(fd, INPUT_EVENT_SIZE * 256)
        except BlockingIOError:
            time.sleep(0.0005)
            continue
        except OSError:
            break
        if not data:
            time.sleep(0.0005)
            continue
        now = time.monotonic()
        for off in range(0, len(data) - INPUT_EVENT_SIZE + 1, INPUT_EVENT_SIZE):
            _s, _us, etype, code, _val = struct.unpack_from(INPUT_EVENT_FMT, data, off)
            if etype == EV_SYN and code == SYN_REPORT:
                if t0 is None:
                    t0 = now
                    print("[gk] 检测到触摸，开始计时 %.1f 秒 —— 请持续滑动" % args.seconds, flush=True)
                n_syn += 1
                frames.append(now)
                frame_pts.append(pending)
                pending = 0
            elif etype == EV_ABS:
                n_abs += 1
                pending += 1
            elif etype == EV_KEY and code == BTN_TOUCH:
                n_key += 1
    os.close(fd)

    c_tot1, c_idle1 = cpu_total()
    irq_after = sum_irqs()

    gaps = [1000.0 * (frames[i] - frames[i - 1]) for i in range(1, len(frames))]
    gaps_sorted = sorted(gaps)
    # 剔除停顿：只累计 < 100 ms 的间隔，得到"真正在触摸中"的有效时长与帧率
    # （否则中途松手几秒会把 rate_hz 严重拉低，两条通路无法公平比较）
    active = sum(g for g in gaps if g < 100.0) / 1000.0 if gaps else 0.0
    med = percentile(gaps_sorted, 0.50) if gaps_sorted else float("nan")
    n_long = sum(1 for g in gaps if med == med and g > 2 * med) if gaps_sorted else 0

    # 有效时长 = 第一帧到最后一帧（不是请求的窗口长度），这样两条通路可比
    dur = (frames[-1] - frames[0]) if len(frames) > 1 else args.seconds
    cpu_pct = 100.0 * ((c_tot1 - c_tot0) - (c_idle1 - c_idle0)) / max(1, c_tot1 - c_tot0)

    res = {
        "label": args.label,
        "device": dev,
        "device_name": name,
        "seconds": dur,
        "requested_seconds": args.seconds,
        "frames": n_syn,
        "rate_hz": round(n_syn / dur, 2),
        "active_seconds": round(active, 3),
        "rate_active_hz": round((n_syn - 1) / active, 2) if active > 0 else None,
        "gap_ms": {
            "median": round(med, 3) if gaps_sorted else None,
            "p95": round(percentile(gaps_sorted, 0.95), 3) if gaps_sorted else None,
            "p99": round(percentile(gaps_sorted, 0.99), 3) if gaps_sorted else None,
            "max": round(max(gaps), 3) if gaps_sorted else None,
        },
        "long_gaps": n_long,
        "ev_abs": n_abs,
        "ev_key_btn_touch": n_key,
        "pts_per_frame": round(sum(frame_pts) / max(1, len(frame_pts)), 2),
        "irq_delta": irq_after - irq_before,
        "irq_per_frame": round((irq_after - irq_before) / max(1, n_syn), 3),
        "cpu_busy_pct": round(cpu_pct, 2),
    }

    print("\n================ 结果 ================")
    print(f"标签            : {res['label']}")
    print(f"帧数 / 帧率     : {res['frames']} 帧 / {res['rate_hz']} Hz")
    print(f"有效时长/帧率   : {res['active_seconds']} s / {res['rate_active_hz']} Hz （剔除 >100ms 停顿）")
    print(f"帧间隔 中位/p95 : {res['gap_ms']['median']} / {res['gap_ms']['p95']} ms")
    print(f"         p99/max: {res['gap_ms']['p99']} / {res['gap_ms']['max']} ms")
    print(f"长间隔(>2×中位) : {res['long_gaps']}")
    print(f"ABS 事件 / 每帧 : {res['ev_abs']} / {res['pts_per_frame']}")
    print(f"触屏 IRQ 增量   : {res['irq_delta']}（每帧 {res['irq_per_frame']}）")
    print(f"CPU 忙          : {res['cpu_busy_pct']} %")
    print("JSON: " + json.dumps(res, ensure_ascii=False))

    if args.json:
        with open(args.json, "a") as f:
            f.write(json.dumps(res, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
