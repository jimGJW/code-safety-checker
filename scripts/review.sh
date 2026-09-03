#!/usr/bin/env bash
# ==============================================================================
# review.sh — 本地快速代码安全审查引擎（自包含）
#
# 与 run-checks.sh（Linux/Docker/CI 全量检查）互补，专为本地快速审查设计：
#   - 兼容 macOS 自带 bash 3.2（不用 declare -A / mapfile / ${var,,}）
#   - 兼容 toybox/BSD grep（不用 grep -P，只用 ERE：grep -E / grep -Ei）
#   - 零外部依赖，几秒内出结果，可直接接入 git pre-commit hook
#
# 用法:
#   ./review.sh --dir <路径>      扫描整个目录（密钥 + 常见代码安全模式）
#   ./review.sh --staged          仅扫描 git 暂存区文件（提交前快速门禁）
#   ./review.sh --diff <base>     扫描与 <base> 的差异（merge/review 场景）
#   ./review.sh --json            输出 JSON 便于程序解析
#
# 退出码: 0=通过  1=发现 critical/high 问题  2=参数错误
# ==============================================================================

set -o pipefail

# ---- 颜色（无 tty 时自动关闭，避免 CI 乱码）----
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

# ---- 全局状态 ----
MODE="dir"; TARGET="."; BASE="HEAD~1"; WANT_JSON=false
COUNT_CRITICAL=0; COUNT_HIGH=0; COUNT_MEDIUM=0

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      MODE="dir"; TARGET="$2"; shift 2 ;;
    --staged)   MODE="staged"; shift ;;
    --diff)     MODE="diff"; BASE="$2"; shift 2 ;;
    --json)     WANT_JSON=true; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

# ---- 规则定义（并行数组，bash 3.2 安全）----
RULE_NAME=(); RULE_RE=(); RULE_SEV=(); RULE_SUGG=()
_rule() {
  local i=${#RULE_NAME[@]}
  RULE_NAME[i]="$1"; RULE_RE[i]="$2"; RULE_SEV[i]="$3"; RULE_SUGG[i]="$4"
}

# ---- 密钥类 ----
_rule "AWS Access Key"           'AKIA[0-9A-Z]{16}'                                        critical "立即轮换该 Key，移入环境变量/密钥管理系统"
_rule "GitHub PAT"               'gh[pousr]_[A-Za-z0-9]{36,}'                              critical "立即吊销该 Token，改用 Secrets/环境变量"
_rule "私钥内容"                  '-----BEGIN [A-Z ]*PRIVATE KEY-----'                       critical "私钥绝不入库，立即轮换并清理 git 历史"
_rule "数据库连接串(带密码)"       '(mysql|postgres|postgresql|mongodb|redis|mssql)://[^ @]+:[^ @]+@' critical "连接串含明文密码，改用密钥管理/环境变量注入"
_rule "Google 服务账号 Key"       '"type"[[:space:]]*:[[:space:]]*"service_account"'         critical "服务账号凭证泄露，立即吊销并清理历史"
_rule "硬编码密码"                '(password|passwd|pwd)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{6,}["'"'"']' high "密码硬编码，移入 .env/密钥管理，并轮换"
_rule "硬编码 API Key"            '(api[_-]?key|apikey|secret[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_-]{20,}["'"'"']' high "API Key 硬编码，移入环境变量并轮换"
_rule "Bearer Token"             'Bearer[[:space:]]+[A-Za-z0-9_.=-]{20,}'                    high "Token 硬编码，移入环境变量"
_rule "Webhook URL"              'https://hooks\.(slack|discord|teams)\.com/[A-Za-z0-9_/-]+' high "Webhook 泄露，轮换并移入配置中心"
_rule "JWT Token"                'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'        medium "疑似 JWT，确认是否为测试样例，避免泄露真实 token"

# ---- 常见代码安全模式（仅 --dir 全量模式启用）----
if [[ "$MODE" == "dir" || "$MODE" == "diff" ]]; then
  _rule "eval() 代码注入"          'eval[[:space:]]*\('                                    high "用 JSON.parse/显式逻辑替代 eval"
  _rule "new Function() 注入"     'new[[:space:]]+Function[[:space:]]*\('                  high "避免用字符串构造函数"
  _rule "dangerouslySetInnerHTML" 'dangerouslySetInnerHTML'                                high "改用 DOMPurify 清洗后渲染"
  _rule "Vue v-html 指令"         'v-html[[:space:]]*='                                    high "改用文本插值/白名单渲染"
  _rule "innerHTML 直接赋值"       '\.(innerHTML|outerHTML)[[:space:]]*='                   medium "优先用 textContent，或 DOMPurify 清洗"
  _rule "document.write"          'document\.write[[:space:]]*\('                          medium "避免 document.write 注入"
  _rule "命令注入(拼接)"           '(exec|execSync|spawn|system|popen|subprocess\.(call|Popen))[[:space:]]*\([^)]*\+' high "参数数组化，禁止拼接用户输入到命令"
  _rule "shell=True 子进程"       'shell[[:space:]]*=[[:space:]]*True'                     high "避免 shell=True，用参数列表传参"
  _rule "SQL 字符串拼接"           '(SELECT|INSERT|UPDATE|DELETE|DROP)[[:space:]].*[+]'      medium "改用参数化查询/ORM"
fi

# ---- 排除目录/文件 ----
EXCLUDE_DIRS="node_modules .git dist build vendor .venv venv __pycache__ target bin obj .next .nuxt coverage .husky .idea .vscode"
EXCLUDE_GLOB="*.min.js *.min.css *.map *.lock *.png *.jpg *.jpeg *.gif *.pdf *.zip *.gz *.tar *.ico *.woff *.woff2 *.ttf"

# 判断是否文本文件：用 file 命令 + 排除二进制扩展名
is_text() {
  local f="$1"
  # 排除已知二进制扩展名
  case "$f" in
    *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.zip|*.gz|*.tar|*.ico|*.woff|*.woff2|*.ttf|*.exe|*.dll|*.so|*.dylib|*.bin|*.jar|*.class) return 1 ;;
  esac
  # file 判空/二进制
  if command -v file >/dev/null 2>&1; then
    file -b --mime-encoding "$f" 2>/dev/null | grep -qi 'binary' && return 1
  fi
  return 0
}

# 判断是否应排除
is_excluded() {
  local f="$1"
  local d
  for d in $EXCLUDE_DIRS; do
    case "$f" in
      */$d/*|*/$d) return 0 ;;
    esac
  done
  local g
  for g in $EXCLUDE_GLOB; do
    case "$f" in $g) return 0 ;; esac
  done
  # 样例/文档/测试文件豁免（精确匹配，避免误伤含 "test" 的目录名）
  case "$f" in
    *.example|*.sample|*.template|*.md) return 0 ;;
    *.test.*|*.spec.*|*.Test.*|*.Spec.*) return 0 ;;
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|*/specs/*) return 0 ;;
  esac
  return 1
}

# ---- 收集待扫描文件列表 ----
collect_files() {
  local mode="$1"
  case "$mode" in
    staged)
      git diff --cached --name-only --diff-filter=ACM 2>/dev/null
      ;;
    diff)
      git diff --name-only --diff-filter=ACM "${BASE}...HEAD" 2>/dev/null || git diff --name-only --diff-filter=ACM "${BASE}" 2>/dev/null
      ;;
    *)
      # 全量：find 所有常规源码文件
      find "$TARGET" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.jsx' -o -name '*.tsx' -o -name '*.vue' \
        -o -name '*.py' -o -name '*.go' -o -name '*.java' -o -name '*.rb' -o -name '*.php' -o -name '*.rs' \
        -o -name '*.sh' -o -name '*.bash' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.tf' \
        -o -name '*.env' -o -name 'Dockerfile' -o -name '*.properties' -o -name '*.conf' -o -name '*.toml' \) \
        2>/dev/null
      ;;
  esac
}

# ---- 主流程 ----
main() {
  local files
  if [[ "$MODE" == "staged" || "$MODE" == "diff" ]]; then
    [[ -d .git ]] || { echo "当前目录不是 git 仓库"; exit 2; }
  fi
  files=$(collect_files "$MODE")

  if [[ -z "$files" ]]; then
    echo -e "${GREEN}✅ 无待扫描文件${NC}"
    exit 0
  fi

  echo -e "${CYAN}代码安全快速审查 (review.sh)${NC}"
  echo "模式: $MODE  待扫描文件: $(echo "$files" | grep -c .) 个"
  echo ""

  local total=0
  local json_parts=""

  # 逐文件逐规则扫描
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    is_excluded "$f" && continue
    [[ -f "$f" ]] || continue
    is_text "$f" || continue

    local idx=0
    local n=${#RULE_NAME[@]}
    while [[ $idx -lt $n ]]; do
      local re="${RULE_RE[$idx]}"
      local hit
      hit=$(grep -nEi "$re" "$f" 2>/dev/null | head -5)
      if [[ -n "$hit" ]]; then
        local cnt
        cnt=$(grep -cEi "$re" "$f" 2>/dev/null)
        local sev="${RULE_SEV[$idx]}"
        local name="${RULE_NAME[$idx]}"
        local sugg="${RULE_SUGG[$idx]}"
        case "$sev" in
          critical) COUNT_CRITICAL=$((COUNT_CRITICAL + 1)) ;;
          high)     COUNT_HIGH=$((COUNT_HIGH + 1)) ;;
          medium)   COUNT_MEDIUM=$((COUNT_MEDIUM + 1)) ;;
        esac
        total=$((total + 1))
        echo -e "  ${RED}✗${NC} [$sev] ${name}"
        echo -e "     文件: ${f}  (共 ${cnt} 处)"
        echo "$hit" | while IFS= read -r line; do
          echo -e "     ${YELLOW}↳${NC} ${line}"
        done
        echo -e "     ${CYAN}建议:${NC} ${sugg}"
        echo ""
      fi
      idx=$((idx + 1))
    done
  done <<< "$files"

  # ---- 汇总 ----
  echo "----------------------------------------"
  echo -e "汇总: ${RED}Critical ${COUNT_CRITICAL}${NC} | ${RED}High ${COUNT_HIGH}${NC} | ${YELLOW}Medium ${COUNT_MEDIUM}${NC} | 命中规则 ${total} 项"
  if [[ $((COUNT_CRITICAL + COUNT_HIGH)) -gt 0 ]]; then
    echo -e "${RED}⛔ 审查不通过：存在 critical/high 问题，建议修复后再提交。${NC}"
    echo -e "   如需强制提交: git commit --no-verify  （不推荐）"
    exit 1
  elif [[ $COUNT_MEDIUM -gt 0 ]]; then
    echo -e "${YELLOW}⚠️  发现 medium 级别提示，请人工确认是否为误报。${NC}"
    exit 0
  else
    echo -e "${GREEN}✅ 审查通过：未发现密钥或明显安全风险。${NC}"
    exit 0
  fi
}

main "$@"
