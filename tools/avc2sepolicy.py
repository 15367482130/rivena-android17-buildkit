#!/usr/bin/env python3
"""
从编译 / 运行日志里提取 SELinux 拒绝，生成 allow 规则草稿。

支持两种格式（同一个日志里混着也行）：
  1) 编译期 neverallow 违规：
     libsepol.report_failure: neverallow on line 123 of ... violated by allow system_server sysfs_x:file { read write };
  2) 运行期 avc 拒绝（dmesg / logcat）：
     avc: denied { read } for pid=1 comm="init" name="x" scontext=u:r:vendor_init:s0 tcontext=u:r:sysfs:s0 tclass=file permissive=0

用法:
  ./avc2sepolicy.py build.log                # 只打印摘要
  ./avc2sepolicy.py build.log -o rules.te    # 同时写出规则草稿
  ./avc2sepolicy.py --min-count 2 build.log  # 出现 2 次以上的才输出

注意:
  neverallow 违规**不是**加 allow 能解决的 —— 那是核心策略在禁止某条访问路径，
  正确做法是改代码（换 API / 换属性 / 用正确的 domain），或给 vendor 侧单独建 domain。
  本工具把两类分开列，避免你把 neverallow 当成权限缺失去补 allow。
"""
import argparse
import collections
import re
import sys

NEVERALLOW = re.compile(
    r"violated by allow\s+(?P<s>\S+)\s+(?P<t>\S+):(?P<c>\S+)\s*\{\s*(?P<p>[^}]*)\}"
)
NEVERALLOW_LINE = re.compile(r"neverallow on line (\d+) of (\S+)")
AVC = re.compile(r"avc:\s+denied\s+\{(?P<p>[^}]*)\}.*?"
                 r"scontext=(?P<s>\S+)\s+tcontext=(?P<t>\S+)\s+tclass=(?P<c>\S+)")


def ctx_type(con):
    """u:r:vendor_init:s0 -> vendor_init"""
    parts = con.split(":")
    return parts[2] if len(parts) >= 3 else con


def perms(raw):
    return sorted({p for p in raw.split() if p})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("-o", "--out")
    ap.add_argument("--min-count", type=int, default=1)
    a = ap.parse_args()

    never, avc = collections.Counter(), collections.Counter()
    never_src = {}
    total_lines = 0

    with open(a.log, "r", errors="replace") as f:
        for line in f:
            total_lines += 1
            m = NEVERALLOW.search(line)
            if m:
                key = (m["s"], m["t"], m["c"], tuple(perms(m["p"])))
                never[key] += 1
                lm = NEVERALLOW_LINE.search(line)
                if lm and key not in never_src:
                    never_src[key] = f"{lm.group(2)}:{lm.group(1)}"
                continue
            m = AVC.search(line)
            if m:
                key = (ctx_type(m["s"]), ctx_type(m["t"]), m["c"], tuple(perms(m["p"])))
                avc[key] += 1

    def emit(counter, title, header, src=False):
        rows = [(k, v) for k, v in counter.items() if v >= a.min_count]
        rows.sort(key=lambda kv: -kv[1])
        if not rows:
            return []
        out = [f"# ===== {title}（{len(rows)} 类，共 {sum(counter.values())} 次）====="]
        for i, (k, n) in enumerate(rows, 1):
            s, t, c, p = k
            if src:
                out.append(f"# {i}) 出现 {n} 次，规则来源 {never_src.get(k, '未知')}")
            else:
                out.append(f"# {i}) 出现 {n} 次")
            out.append(header.format(s=s, t=t, c=c, perms=" ".join(p)))
            out.append("")
        return out

    body = []
    body += emit(never, "neverallow 违规（改代码，不是加 allow）",
                 "# 需要处理：allow {s} {t}:{c} {{ {perms} }};", src=True) or \
            ["# 没有发现 neverallow 违规", ""]
    body += emit(avc, "avc 拒绝（可以补 allow）",
                 "allow {s} {t}:{c} {{ {perms} }};") or ["# 没有发现 avc 拒绝", ""]

    print(f"扫描 {a.log}：{total_lines} 行")
    print(f"  neverallow 违规 {sum(never.values())} 次 / {len(never)} 类")
    print(f"  avc 拒绝      {sum(avc.values())} 次 / {len(avc)} 类")
    for line in body:
        print(line)

    if a.out:
        with open(a.out, "w") as f:
            f.write(f"# 由 avc2sepolicy.py 从 {a.log} 生成，仅为草稿\n")
            f.write("# 放置位置：device/oppo/sm8250-common/sepolicy/vendor/*.te\n")
            f.write("# 每条规则都要问自己：这个访问真的必要吗？能不能改代码绕开？\n\n")
            f.write("\n".join(body))
        print(f"规则草稿已写入 {a.out}")

    if never:
        print("\n提示：neverallow 是核心策略的硬约束，往 device sepolicy 里加 allow 不会生效，"
              "必须改访问方或被访问方的类型/路径。")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
