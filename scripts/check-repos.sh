#!/usr/bin/env bash
# ==============================================================================
# check-repos.sh —— 批量检查 config/repos.json 中登记的所有远程仓库
#
# 工作流：
#   1. 读取 ${CHECKER_ROOT}/config/repos.json
#   2. 对每个 enabled!=false 的仓库调用 check-remote.sh
#   3. 汇总每个仓库的结果，生成 reports/index.md 总览文档
#
# 用法:
#   ./scripts/check-repos.sh                      # 检查 repos.json 中所有启用的仓库
#   ./scripts/check-repos.sh --only secret,dep    # 对所有仓库只跑指定检查
#   ./scripts/check-repos.sh --strict             # 所有仓库启用严格模式
#   ./scripts/check-repos.sh --config /path/repos.json
#   ./scripts/check-repos.sh --filter <name>      # 只检查名称匹配的仓库（grep 模糊匹配）
#
# 注：命令行传入的 --only/--skip/--strict 会覆盖 repos.json 里每条记录的对应字段。
# ==============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${CHECKER_ROOT}/config/repos.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# -------------------- 参数解析 --------------------
GLOBAL_ONLY=""
GLOBAL_SKIP=""
GLOBAL_STRICT=""
FILTER=""

usage() {
  sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    --only)    GLOBAL_ONLY="$2"; shift 2 ;;
    --skip)    GLOBAL_SKIP="$2"; shift 2 ;;
    --strict)  GLOBAL_STRICT="true"; shift ;;
    --filter)  FILTER="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}❌ 配置文件不存在: $CONFIG_FILE${NC}"
  exit 2
fi

# -------------------- JSON 解析（jq 优先，Python 兜底） --------------------
# 返回 repos 数组长度
json_repo_count() {
  if command -v jq >/dev/null 2>&1; then
    jq '.repos | length' "$CONFIG_FILE"
  else
    _python_json '.repos | length'
  fi
}

# 返回第 i 条记录的某字段（raw，字符串不加引号）
json_field() {
  local idx="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg i "$idx" --arg k "$key" '.repos[$i|tonumber][$k] // ""' "$CONFIG_FILE"
  else
    _python_json ".repos[$1][$2]" "$1" "$2"
  fi
}

_python_json() {
  local expr="$1"; shift
  local py
  if command -v python3 >/dev/null 2>&1; then py="python3"; else py="python"; fi
  "$py" - "$CONFIG_FILE" "$expr" "$@" <<'PY'
import json, sys
cfg, expr = sys.argv[1], sys.argv[2]
# 支持简单下标占位符替换 repos[$i][$k]
args = sys.argv[3:]
e = expr
if '$i' in e and args: e = e.replace('$i', args[0])
if '$k' in e and len(args) > 1: e = e.replace('$k', repr(args[1]))
with open(cfg) as f:
    data = json.load(f)
try:
    val = eval(e, {"__builtins__": {}}, {"repos": data.get("repos", [])})
except Exception:
    val = ""
if isinstance(val, (list, dict)):
    print(len(val) if isinstance(val, list) else "")
else:
    print("" if val is None else val)
PY
}

COUNT="$(json_repo_count)"
if [[ -z "$COUNT" || "$COUNT" == "0" ]]; then
  echo -e "${YELLOW}⚠️ 配置中没有启用的仓库: $CONFIG_FILE${NC}"
  exit 0
fi

echo -e "${CYAN}📚 批量远程仓库检查${NC}"
echo -e "  配置: ${CONFIG_FILE}"
echo -e "  仓库数: ${COUNT}"
[[ -n "$FILTER" ]] && echo -e "  过滤: ${FILTER}"
echo ""

# -------------------- 逐个检查 --------------------
declare -a SLUGS RESULTS EXITS REPORTS
START_TS=$(date +%s)

i=0
while [[ $i -lt $COUNT ]]; do
  url="$(json_field "$i" url)"
  name="$(json_field "$i" name)"
  branch="$(json_field "$i" branch)"
  depth="$(json_field "$i" depth)"
  strict="$(json_field "$i" strict)"
  only="$(json_field "$i" only)"
  skip="$(json_field "$i" skip)"
  enabled="$(json_field "$i" enabled)"

  [[ -z "$enabled" ]] && enabled="true"

  if [[ "$enabled" != "true" ]]; then
    echo -e "${YELLOW}⏭️  跳过（未启用）: ${name:-$url}${NC}"
    SLUGS+=("${name:-$url}"); RESULTS+=("skipped"); EXITS+=("0"); REPORTS+=("")
    i=$((i + 1)); continue
  fi

  # 名称过滤
  if [[ -n "$FILTER" ]]; then
    target="${name:-$url}"
    if ! echo "$target" | grep -q "$FILTER"; then
      i=$((i + 1)); continue
    fi
  fi

  # 命令行参数覆盖配置
  [[ -n "$GLOBAL_ONLY" ]] && only="$GLOBAL_ONLY"
  [[ -n "$GLOBAL_SKIP" ]] && skip="$GLOBAL_SKIP"
  [[ -n "$GLOBAL_STRICT" ]] && strict="$GLOBAL_STRICT"

  args=("$url")
  [[ -n "$branch" ]] && args+=(--branch "$branch")
  [[ -n "$depth" ]] && args+=(--depth "$depth")
  [[ -n "$only" ]] && args+=(--only "$only")
  [[ -n "$skip" ]] && args+=(--skip "$skip")
  [[ "$strict" == "true" ]] && args+=(--strict)

  echo -e "${CYAN}========================================${NC}"
  echo -e "${CYAN} [$((i+1))/$COUNT] ${name:-$url}${NC}"
  echo -e "${CYAN}========================================${NC}"

  # 调用 check-remote.sh，捕获其最后输出的报告路径
  out="$(bash "${SCRIPT_DIR}/check-remote.sh" "${args[@]}" 2>&1)"
  rc=$?
  echo "$out"

  # 从输出抽取报告文件路径（匹配「检查文档:」行）
  rpt="$(echo "$out" | grep -E '检查文档:' | sed -E 's/.*📄[^:]*: *//' | tail -1)"
  # 去 ANSI
  rpt="$(echo "$rpt" | sed -E 's/\x1b\[[0-9;]*m//g' | xargs)"

  SLUGS+=("${name:-$url}")
  if [[ $rc -eq 0 ]]; then
    RESULTS+=("passed")
  else
    RESULTS+=("failed")
  fi
  EXITS+=("$rc")
  REPORTS+=("$rpt")

  i=$((i + 1))
done

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

# -------------------- 生成总览 index.md --------------------
INDEX_FILE="${CHECKER_ROOT}/reports/index.md"
mkdir -p "${CHECKER_ROOT}/reports"

passed_n=0; failed_n=0; skipped_n=0
for r in "${RESULTS[@]}"; do
  case "$r" in
    passed)  passed_n=$((passed_n + 1)) ;;
    failed)  failed_n=$((failed_n + 1)) ;;
    skipped) skipped_n=$((skipped_n + 1)) ;;
  esac
done

{
  echo "# 远程仓库批量检查总览"
  echo ""
  echo "**生成时间**: $(date '+%Y-%m-%d %H:%M:%S %z')  "
  echo "**配置文件**: \`${CONFIG_FILE}\`  "
  echo "**总耗时**: ${DURATION} 秒  "
  echo "**结果**: ✅ 通过 ${passed_n}  |  ❌ 失败 ${failed_n}  |  ⏭️  跳过 ${skipped_n}"
  echo ""
  echo "## 明细"
  echo ""
  echo "| # | 仓库 | 结果 | 退出码 | 报告 |"
  echo "|---|------|------|--------|------|"
  j=0
  for r in "${RESULTS[@]}"; do
    idx=$((j + 1))
    icon=""
    case "$r" in
      passed) icon="✅" ;;
      failed) icon="❌" ;;
      skipped) icon="⏭️" ;;
    esac
    rpt="${REPORTS[$j]}"
    if [[ -n "$rpt" ]]; then
      # 转成相对路径链接
      rel="${rpt#${CHECKER_ROOT}/}"
      rpt_link="[查看](../${rel})"
    else
      rpt_link="-"
    fi
    echo "| ${idx} | ${SLUGS[$j]} | ${icon} ${r} | ${EXITS[$j]} | ${rpt_link} |"
    j=$((j + 1))
  done
  echo ""
  echo "> 各仓库详细报告位于 \`reports/<仓库名>/\` 目录下，\`latest-report.md\` 始终指向最近一次检查结果。"
} > "$INDEX_FILE"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} 📊 批量检查完成${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  ⏱️  耗时: ${DURATION} 秒"
echo -e "  ✅ 通过: ${passed_n}    ❌ 失败: ${failed_n}    ⏭️  跳过: ${skipped_n}"
echo -e "  📄 总览: ${INDEX_FILE}"
echo ""

# 任一仓库失败则整体失败
overall=0
for e in "${EXITS[@]}"; do
  [[ "$e" -ne 0 ]] && overall=1
done
exit $overall
