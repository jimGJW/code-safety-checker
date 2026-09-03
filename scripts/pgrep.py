#!/usr/bin/env python3
# ==============================================================================
# pgrep.py — PCRE grep 兜底（macOS toybox/BSD grep 不支持 `grep -P` 时使用）
#
# 用法:
#   单规则模式:
#     pgrep.py <pattern> [--recursive] [--exclude-dir D]... [--exclude F]... <DIR|FILE>...
#     输出: 每行 "path:lineno:content"，最多 50 行
#
#   批量模式 (一次遍历匹配多条规则，显著减少 Python 启动开销):
#     pgrep.py --batch <rules_file> [--exclude-dir D]... [--exclude F]... <DIR|FILE>...
#     rules_file 每行格式:  NAME<TAB>PATTERN
#     输出: 每行 "NAME<TAB>path:lineno:content"，每条规则最多 50 行
#
# 说明: 使用 Python `re` 模块，支持 (?i) 内联标志、\s \d \w、(?=..)(?!..) 等
#       PCRE 常用子集，覆盖本项目内置规则所需全部语法。
# ==============================================================================
import sys
import os
import re
import fnmatch

MAX_HITS = 50

# 默认排除目录
DEFAULT_EXCLUDE_DIRS = {
    "node_modules", ".git", "dist", "build", "vendor", ".venv", "venv",
    "__pycache__", "target", "bin", "obj", ".next", ".nuxt", ".cache",
    "coverage", ".husky", ".idea", ".vscode", ".terraform", ".mypy_cache",
}

# 默认排除文件（二进制/锁文件，避免误扫）
DEFAULT_EXCLUDE_FILES = (
    "*.min.js", "*.min.css", "*.map", "*.png", "*.jpg", "*.jpeg", "*.gif",
    "*.pdf", "*.zip", "*.tar", "*.tar.*", "*.gz", "*.bz2", "*.xz", "*.ico",
    "*.woff", "*.woff2", "*.ttf", "*.eot", "*.lock", "*.jar", "*.class",
    "*.so", "*.dylib", "*.exe", "*.dll", "*.bin", "*.pyc",
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "go.sum",
    "Cargo.lock", "composer.lock",
)


def parse_args(argv):
    """解析排除参数与目标，返回 (exclude_dirs, exclude_files, targets)"""
    exclude_dirs = set(DEFAULT_EXCLUDE_DIRS)
    exclude_files = list(DEFAULT_EXCLUDE_FILES)
    targets = []

    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--recursive":
            i += 1
        elif a == "--exclude-dir":
            if i + 1 < len(argv):
                exclude_dirs.add(argv[i + 1]); i += 2
            else:
                i += 1
        elif a.startswith("--exclude-dir="):
            exclude_dirs.add(a.split("=", 1)[1]); i += 1
        elif a == "--exclude":
            if i + 1 < len(argv):
                exclude_files.append(argv[i + 1]); i += 2
            else:
                i += 1
        elif a.startswith("--exclude="):
            exclude_files.append(a.split("=", 1)[1]); i += 1
        else:
            targets.append(a); i += 1
    return exclude_dirs, exclude_files, targets


def collect_files(exclude_dirs, exclude_files, targets):
    def is_excluded_file(name):
        for pat in exclude_files:
            if fnmatch.fnmatch(name, pat):
                return True
        return False

    files = []
    seen = set()
    for t in targets:
        if os.path.isdir(t):
            for root, dirs, fs in os.walk(t):
                dirs[:] = [d for d in dirs if d not in exclude_dirs]
                for f in fs:
                    if is_excluded_file(f):
                        continue
                    p = os.path.join(root, f)
                    if p not in seen:
                        seen.add(p)
                        files.append(p)
        elif os.path.isfile(t):
            if not is_excluded_file(os.path.basename(t)):
                if t not in seen:
                    seen.add(t)
                    files.append(t)
    return files


def is_text(path):
    # 轻量二进制检测：读前 8KB，含 NUL 字节则视为二进制
    try:
        with open(path, "rb") as fh:
            chunk = fh.read(8192)
        return b"\x00" not in chunk
    except (OSError, IOError):
        return False


def iter_text_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for lineno, line in enumerate(fh, 1):
                yield lineno, line.rstrip("\n")
    except (OSError, IOError, UnicodeDecodeError):
        return


def main():
    args = sys.argv[1:]
    if not args:
        return 0

    batch = False
    if args[0] == "--batch":
        batch = True
        args = args[1:]
        if not args:
            return 0
        rules_file = args[0]
        rest = args[1:]
    else:
        pattern = args[0]
        rest = args[1:]

    exclude_dirs, exclude_files, targets = parse_args(rest)

    if batch:
        # 读取规则文件: NAME<TAB>PATTERN
        rules = []
        try:
            with open(rules_file, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    if "\t" in line:
                        name, pat = line.split("\t", 1)
                    else:
                        name, pat = line, line
                    try:
                        rx = re.compile(pat)
                    except re.error as e:
                        sys.stderr.write("pgrep: 正则编译失败 [%s]: %s\n" % (name, e))
                        continue
                    rules.append((name, rx))
        except (OSError, IOError) as e:
            sys.stderr.write("pgrep: 无法读取规则文件 %s: %s\n" % (rules_file, e))
            return 2

        if not rules:
            return 0

        hits = {name: 0 for name, _ in rules}
        files = collect_files(exclude_dirs, exclude_files, targets)
        for path in files:
            if not is_text(path):
                continue
            for lineno, line in iter_text_lines(path):
                for name, rx in rules:
                    if hits[name] >= MAX_HITS:
                        continue
                    if rx.search(line):
                        print("%s\t%s:%d:%s" % (name, path, lineno, line))
                        hits[name] += 1
        return 0

    # 单规则模式（向后兼容 grep_p）
    try:
        rx = re.compile(pattern)
    except re.error as e:
        sys.stderr.write("pgrep: 正则编译失败: %s (pattern=%s)\n" % (e, pattern))
        return 2

    files = collect_files(exclude_dirs, exclude_files, targets)
    count = 0
    for path in files:
        if not is_text(path):
            continue
        for lineno, line in iter_text_lines(path):
            if rx.search(line):
                print("%s:%d:%s" % (path, lineno, line))
                count += 1
                if count >= MAX_HITS:
                    return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
