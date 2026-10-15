"""无 PyYAML 环境下的 GitHub Actions 工作流结构自检。
重点检查「块标量（run: |）的缩进」——这是 Actions YAML 最常见的翻车点。
"""
import re
import sys

path = r"C:\Users\Administrator\Documents\deepseek-harness\default-workspace\timefloat\.github\workflows\ios-ipa.yml"

raw = open(path, encoding="utf-8").read()
lines = raw.split("\n")

problems = []

# 1) 不允许 tab
for i, ln in enumerate(lines, 1):
    if "\t" in ln:
        problems.append("第 %d 行含 TAB（YAML 禁止用 TAB 缩进）" % i)

# 2) 缩进必须是 2 的倍数且没有奇怪的全角空格
for i, ln in enumerate(lines, 1):
    if not ln.strip():
        continue
    indent = len(ln) - len(ln.lstrip(" "))
    if indent % 2 != 0:
        problems.append("第 %d 行缩进为 %d（不是 2 的倍数）" % (i, indent))
    if "\u3000" in ln:
        problems.append("第 %d 行含全角空格" % i)

# 3) 块标量：run: | / | / > 后面的内容必须比 key 缩进更深
block_start = None
block_indent = None
for i, ln in enumerate(lines, 1):
    if not ln.strip() or ln.lstrip().startswith("#"):
        continue
    indent = len(ln) - len(ln.lstrip(" "))
    if block_start is not None:
        if indent <= block_indent:
            block_start = None  # 块结束，落到下面的正常检查
        else:
            continue
    if re.search(r":\s*\|[-+]?\s*$", ln):
        block_start = i
        block_indent = indent
        continue

# 4) 关键结构
checks = {
    "name": bool(re.search(r"^name:\s*\S+", raw, re.M)),
    "workflow_dispatch": "workflow_dispatch:" in raw,
    "runs-on": "runs-on:" in raw,
    "checkout": "actions/checkout@v4" in raw,
    "upload-artifact": "actions/upload-artifact@v4" in raw,
    "xcodegen": "xcodegen generate" in raw,
    "xcodebuild archive": "archive" in raw and "xcodebuild" in raw,
    "包名可覆盖": 'PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"' in raw,
    "未签名编译": "CODE_SIGNING_ALLOWED=NO" in raw,
}

print("文件行数:", len(lines))
print()
print("结构检查:")
for k, v in checks.items():
    print("  %-16s %s" % (k, "OK" if v else "缺失!"))
    if not v:
        problems.append("缺少关键内容: %s" % k)

# 5) 真 YAML 语法咱们没法完全验证，但把每个 run 块打印出来人工核对
print()
print("块内容预览:")
for i, ln in enumerate(lines, 1):
    if re.search(r"run:\s*\|", ln):
        base = len(ln) - len(ln.lstrip(" "))
        print("  ---- run 块（第 %d 行，缩进 %d）----" % (i, base))
        j = i
        while j < len(lines):
            nxt = lines[j]
            if nxt.strip() and (len(nxt) - len(nxt.lstrip(" "))) <= base:
                break
            if nxt.strip():
                print("    " + nxt.strip()[:100])
            j += 1

print()
if problems:
    print("发现 %d 个问题：" % len(problems))
    for p in problems:
        print("  [FAIL]", p)
    sys.exit(1)
else:
    print("[OK] 结构自检通过：无 TAB、缩进规范、run 块正常、关键步骤齐全")
