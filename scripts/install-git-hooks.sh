#!/usr/bin/env bash
# ==============================================================================
# install-git-hooks.sh — 把「提交前代码安全审查」hook 安装到任意 git 仓库
#
# 用法:
#   ./scripts/install-git-hooks.sh                 # 安装到当前目录的仓库
#   ./scripts/install-git-hooks.sh /path/to/repo   # 安装到指定仓库
#   ./scripts/install-git-hooks.sh --global        # 安装到全局 git 模板（对所有新仓库生效）
#
# 安装后，无论用 SourceTree / 命令行 git / IDE，每次 commit 都会自动跑
# review.sh --staged，命中高危密钥时阻止提交，并打印审查结论。
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GLOBAL_MODE=false
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --global) GLOBAL_MODE=true; shift ;;
    *) TARGET="$1"; shift ;;
  esac
done

install_into() {
  local hooks_dir="$1"
  mkdir -p "$hooks_dir"
  cp "$SCRIPT_DIR/review.sh"        "$hooks_dir/review.sh"
  cp "$SCRIPT_DIR/hooks/pre-commit" "$hooks_dir/pre-commit"
  chmod +x "$hooks_dir/review.sh" "$hooks_dir/pre-commit"
  echo "✅ 已安装到 $hooks_dir"
  echo "   - $hooks_dir/pre-commit"
  echo "   - $hooks_dir/review.sh"
}

if $GLOBAL_MODE; then
  # 全局模板：git init 新仓库时自动带上（需用 git config --global init.templateDir 启用）
  TEMPLATE_DIR="${TEMPLATE_DIR:-$HOME/.git-template}"
  mkdir -p "$TEMPLATE_DIR/hooks"
  install_into "$TEMPLATE_DIR/hooks"
  git config --global init.templateDir "$TEMPLATE_DIR"
  echo "✅ 已设置全局 git 模板目录: $TEMPLATE_DIR"
  echo "   注意：只对「之后新 init/clone 的仓库」自动生效；"
  echo "   已有仓库请单独执行: ./scripts/install-git-hooks.sh <仓库路径>"
  exit 0
fi

TARGET="${TARGET:-.}"
if [[ ! -d "$TARGET/.git" ]]; then
  echo "❌ $TARGET 不是 git 仓库（未找到 .git 目录）"
  exit 1
fi

install_into "$TARGET/.git/hooks"

echo ""
echo "提示:"
echo "  - 提交时自动审查暂存文件，命中高危密钥会阻止提交"
echo "  - 强制跳过: git commit --no-verify 或 SKIP_SAFETY=1 git commit"
echo "  - 手动跑一次完整快速审查: ./scripts/review.sh --dir <仓库路径>"
