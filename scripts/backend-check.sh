#!/usr/bin/env bash
# ==============================================================================
# 后端代码安全与可靠性检查 (Backend Security & Reliability)
# 支持 Node.js / Python / Go / Java / Ruby 主流后端栈
# 检查: SQL注入、命令注入、SSRF、XXE、路径穿越、认证绕过、空指针、资源泄露等
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SCAN_DIR="${1:-.}"
REPORT_TXT="${REPORT_DIR}/backend-check.txt"

PROJECT_TYPES=""

detect_backend_stacks() {
  PROJECT_TYPES=($(detect_project_type "${SCAN_DIR}" | tr ' ' '\n' | grep "^backend-" | sort -u))
  # 后端代码典型目录：也用作兜底扫描
  echo "检测到后端技术栈: ${PROJECT_TYPES[*]:-未明确识别（将进行通用扫描）}"
}

find_backend_files() {
  # 按不同语言返回相应文件列表
  local patterns=()
  for t in "${PROJECT_TYPES[@]:-backend-nodejs backend-python backend-golang}"; do
    case "$t" in
      *nodejs*) patterns+=("*.js" "*.ts") ;;
      *python*) patterns+=("*.py") ;;
      *golang*) patterns+=("*.go") ;;
      *java*)   patterns+=("*.java") ;;
      *ruby*)   patterns+=("*.rb") ;;
      *rust*)   patterns+=("*.rs") ;;
      *php*)    patterns+=("*.php") ;;
    esac
  done

  local find_args=()
  for p in "${patterns[@]}"; do find_args+=("-name" "$p" "-o"); done
  unset 'find_args[${#find_args[@]}-1]'

  find "${SCAN_DIR}" -type f \( "${find_args[@]}" \) \
    ! -path "*/node_modules/*" \
    ! -path "*/.venv/*" \
    ! -path "*/__pycache__/*" \
    ! -path "*/vendor/*" \
    ! -path "*/dist/*" \
    ! -path "*/build/*" \
    ! -path "*/target/*" \
    ! -name "*.min.js" \
    2>/dev/null || true
}

run_bandit() {
  # Python 安全扫描
  local issues=0
  log_section "Python: Bandit 安全扫描"

  local py_files
  py_files=$(find "${SCAN_DIR}" -name "*.py" -not -path "*__pycache__*" -not -path "*.venv*" 2>/dev/null | head -1)
  [[ -z "$py_files" ]] && { echo 0; return; }

  if command_exists bandit; then
    bandit -r "${SCAN_DIR}" -f json -o "${REPORT_DIR}/bandit-report.json" \
      --exclude "tests,test,migrations,venv,__pycache__" -q 2>/dev/null || true
    if command_exists jq && [[ -s "${REPORT_DIR}/bandit-report.json" ]]; then
      issues=$(jq '.results | length' "${REPORT_DIR}/bandit-report.json" 2>/dev/null || echo 0)
    fi
    log_info "Bandit 发现 ${issues} 个问题"
  else
    log_warn "bandit 未安装，使用内置规则扫描 (pip install bandit)"
  fi
  echo "$issues"
}

run_gosec() {
  # Go 安全扫描
  local issues=0
  log_section "Go: gosec 安全扫描"

  [[ ! -f "${SCAN_DIR}/go.mod" ]] && { echo 0; return; }

  if command_exists gosec; then
    (cd "${SCAN_DIR}" && gosec -fmt json -out "${REPORT_DIR}/gosec-report.json" ./... 2>/dev/null || true)
    if command_exists jq && [[ -s "${REPORT_DIR}/gosec-report.json" ]]; then
      issues=$(jq '.Issues | length' "${REPORT_DIR}/gosec-report.json" 2>/dev/null || echo 0)
    fi
    log_info "gosec 发现 ${issues} 个问题"
  else
    log_warn "gosec 未安装，使用内置规则 (go install github.com/securecodewarrior/gosec/v2/cmd/gosec@latest)"
  fi
  echo "$issues"
}

run_builtin_backend_rules() {
  # 内置通用后端安全规则（零依赖 grep 实现）
  local issues=0
  declare -a backend_files
  mapfile -t backend_files < <(find_backend_files)
  local total_files="${#backend_files[@]}"
  log_info "扫描后端源文件: ${total_files} 个"

  if [[ $total_files -eq 0 ]]; then
    echo 0
    return
  fi

  : > "${REPORT_TXT}.rules.tmp"

  # 通用安全规则（跨语言）
  declare -A RULES=(
    ["SQL注入: 字符串拼接 SQL"]="(SELECT|INSERT|UPDATE|DELETE|DROP|UNION)[^;]*\$[{(]?[a-zA-Z_][a-zA-Z0-9_]*[})]?|(SELECT|INSERT|UPDATE)[^;]*\+\s*(req|params|args|input|query|body|form|user)"
    ["SQL注入: format/f-string 拼接 SQL"]="(%s.*SQL|f[\"'][^\"']*(SELECT|INSERT|UPDATE)|sql\s*=\s*format\()"
    ["命令注入: exec/system/spawn 拼接用户输入"]="(exec|execSync|system|spawn|popen|subprocess\.call|subprocess\.Popen|Runtime\.getRuntime\(\)\.exec|os\.Exec)\s*\([^)]*(req\.|params\.|args\[|input|form|body\.|query\.|request\.|user)"
    ["命令注入: 反引号/shell=True"]="shell\s*=\s*True|\$\([^)]*\+"
    ["路径穿越: 直接拼接路径读取文件"]="(readFileSync|readFile|fs\.readFile|open\(|File\(|Path\.join|os\.path\.join)\s*\([^)]*(req\.|params\.|query\.|body\.|form|request)"
    ["SSRF: 可控 URL 的 HTTP 请求"]="(axios|fetch|request|http\.get|requests\.(get|post)|urllib\.|http\.Client)\s*\([^)]*(req\.|params\.|query\.|body\.|input|user)"
    ["XXE: 允许外部实体的 XML 解析"]="(DocumentBuilderFactory|SAXParserFactory|XMLInputFactory|DOMParser)[^;]*setFeature[^;]*false|lxml.*no_network.*False|etree\.XML\("
    ["反序列化: pickle/yaml/ObjectInputStream 不可信数据"]="(pickle\.loads|yaml\.load\s*\(|ObjectInputStream\.readObject|marshal\.load|JSON\.parse.*untrusted)"
    ["不安全加密: MD5/SHA1/ECB/RSA 无填充"]="(md5|sha1|createHash\(['\"]md5|createHash\(['\"]sha1|AES-?ECB|DES|CBC.*NoPadding)"
    ["弱随机数: 用于安全场景"]="(Math\.random|random\.random\(\)|rand\.Intn|crypto/rand\s+\"math/rand\")"
    ["硬编码密钥/密码"]="(api[_-]?key|secret|password|passwd|token)\s*[:=]\s*['\"][A-Za-z0-9_\-]{12,}['\"]"
    ["敏感信息: print/log 泄露"]="(console\.log|print\(|log\.(info|debug|warn))\s*\([^)]*(password|secret|token|jwt|api[_-]?key)"
    ["CORS 配置过于宽松"]="Access-Control-Allow-Origin['\"]?\s*[:=]\s*['\"]\*['\"]"
    ["重定向: 可控跳转"]="(redirect|location\.href|Location:\s*|window\.location\s*=)\s*\(?\s*['\"]?(req\.|params\.|query\.|input|body\.)"
    ["认证绕过: 密码用 == 比较"]="if\s*\([^)]*password[^)]*==|if\s+[^:]*password.*==\s*['\"]"
    ["并发可靠性: 空 db/conn 未判断就使用"]="->(query|execute|Exec|QueryRow)\s*\(\s*\)|\.db\s*->|\.cursor\s*->.*(execute|fetch)"
    ["资源泄露: 缺少 defer/close 模式"]="(open\(|createReadStream|createConnection|connect\(\))[^;\n]{0,200}(?!.*(close\(\)|defer\s|finally\s*\{|\.end\(\)))$"
  )

  local files_list_file
  files_list_file=$(mktemp)
  printf "%s\n" "${backend_files[@]}" > "$files_list_file"

  for rule_name in "${!RULES[@]}"; do
    local pattern="${RULES[$rule_name]}"
    local hits=""
    # 对文件列表逐一 grep
    if command_exists xargs; then
      hits=$(xargs grep -InHP "$pattern" < "$files_list_file" 2>/dev/null | head -50 || true)
    fi
    if [[ -z "$hits" && "$total_files" -lt 2000 ]]; then
      hits=$(grep -InHP "$pattern" "${backend_files[@]}" 2>/dev/null | head -50 || true)
    fi
    if [[ -n "$hits" ]]; then
      local count
      count=$(echo "$hits" | wc -l | tr -d ' ')
      echo "【${rule_name}】发现 ${count} 处:" >> "${REPORT_TXT}.rules.tmp"
      echo "$hits" | head -30 >> "${REPORT_TXT}.rules.tmp"
      echo "" >> "${REPORT_TXT}.rules.tmp"
      issues=$((issues + count))
    fi
  done
  rm -f "$files_list_file"

  if [[ -s "${REPORT_TXT}.rules.tmp" ]]; then
    cat "${REPORT_TXT}.rules.tmp" > "${REPORT_TXT}"
    rm -f "${REPORT_TXT}.rules.tmp"
  fi

  echo "$issues"
}

check_backend_reliability() {
  local issues=0
  log_section "后端可靠性 / 输入校验 / 错误处理"

  # 1. 检查是否有基础的错误处理中间件 (Node.js Express/Koa/Nest)
  if [[ -f "${SCAN_DIR}/package.json" ]]; then
    local has_error_handler=0
    if grep -rn "errorHandler\|app\.use.*err\|app\.use\(.*(err," "${SCAN_DIR}/src" "${SCAN_DIR}/app" 2>/dev/null | head -1 | grep -q .; then
      has_error_handler=1
    fi
    if [[ $has_error_handler -eq 0 ]]; then
      log_warn "未发现统一错误处理中间件，线上容易泄露堆栈或 500 信息"
      issues=$((issues + 1))
    fi

    # 2. 输入校验库：express 项目是否使用 joi/zod/express-validator/class-validator
    local has_validator=0
    for lib in joi zod express-validator class-validator yup ajv; do
      if grep -q "\"${lib}\"" "${SCAN_DIR}/package.json" 2>/dev/null; then
        has_validator=1; break
      fi
    done
    if [[ $has_validator -eq 0 ]]; then
      log_warn "未引入主流的输入校验库，容易存在注入 / 数据越界问题"
      issues=$((issues + 1))
    fi
  fi

  # 3. Python: 是否有 django-rest-framework / pydantic 校验
  if [[ -f "${SCAN_DIR}/requirements.txt" || -f "${SCAN_DIR}/pyproject.toml" ]]; then
    local has_pydantic=0
    for f in "${SCAN_DIR}/requirements.txt" "${SCAN_DIR}/pyproject.toml"; do
      [[ -f "$f" ]] && grep -qE "pydantic|django|fastapi|marshmallow" "$f" && has_pydantic=1
    done
    if [[ $has_pydantic -eq 0 ]]; then
      log_warn "Python 项目未发现 pydantic/django-rest-framework/marshmallow 等校验库"
      issues=$((issues + 1))
    fi
  fi

  # 4. Go: 是否有统一 panic recovery
  if [[ -f "${SCAN_DIR}/go.mod" ]]; then
    local has_recover=0
    grep -rn "recover()" "${SCAN_DIR}" --include="*.go" 2>/dev/null | head -1 | grep -q . && has_recover=1
    if [[ $has_recover -eq 0 ]]; then
      log_warn "Go 项目未发现 recover() panic 恢复机制，单个请求 panic 会拖垮服务"
      issues=$((issues + 1))
    fi
  fi

  # 5. 硬编码配置: 端口/超时等
  local hardcoded
  hardcoded=$(grep -rnE "(listen|port|timeout|dial)\s*[:=]\s*[0-9]+" "${SCAN_DIR}" --include="*.py" --include="*.go" --include="*.js" --include="*.ts" --include="*.java" 2>/dev/null \
    | grep -vE "(\.test\.|\.spec\.|/test/|/tests/|const\s+.*[Tt]imeout|timeout_ms|timeout_seconds|default:" | wc -l | tr -d ' ')
  log_info "硬编码端口/超时配置: ${hardcoded} 处（建议使用 config/env 集中管理）"

  echo "$issues"
}

run_backend_check() {
  log_step "后端代码安全与可靠性检查"
  ensure_dir "${REPORT_DIR}"

  detect_backend_stacks

  # 判断是否有任何后端文件
  local any_file
  any_file=$(find_backend_files | wc -l | tr -d ' ')
  if [[ "$any_file" -eq 0 && ${#PROJECT_TYPES[@]} -eq 0 ]]; then
    record_result "后端代码检查" "skipped" "none" 0 "未检测到后端代码"
    return
  fi

  local bandit_issues=0
  local gosec_issues=0
  local builtin_issues=0
  local reliability_issues=0

  bandit_issues=$(run_bandit)
  gosec_issues=$(run_gosec)
  builtin_issues=$(run_builtin_backend_rules)
  reliability_issues=$(check_backend_reliability)

  local total=$((bandit_issues + gosec_issues + builtin_issues + reliability_issues))
  log_info "后端总问题: bandit=${bandit_issues}, gosec=${gosec_issues}, 内置规则=${builtin_issues}, 可靠性=${reliability_issues}"

  if [[ $builtin_issues -gt 0 || $bandit_issues -gt 0 || $gosec_issues -gt 0 ]]; then
    record_result "后端代码检查" "failed" "high" "$total" \
      "安全类问题 (security=${builtin_issues}+${bandit_issues}+${gosec_issues}, reliability=${reliability_issues})"
    log_error "请查看报告: ${REPORT_TXT}"
    log_error "核心修复建议:"
    log_error "  - SQL 注入: 使用参数化查询/ORM，禁止字符串拼接 SQL"
    log_error "  - 命令注入: 禁止传用户输入给 exec/system；使用白名单或 spawn + args 数组"
    log_error "  - 路径穿越: path.resolve + 校验 prefix 不跳出允许目录"
    log_error "  - SSRF: URL 白名单 / 内网网段禁用 / 只允许 https 域名"
    log_error "  - 输入校验: 引入 joi/zod/pydantic 对所有外部入参强校验"
    log_error "  - 资源泄露: defer close / try-with-resources / finally 释放"
  elif [[ $reliability_issues -gt 0 ]]; then
    record_result "后端代码检查" "failed" "medium" "$total" "可靠性问题: ${reliability_issues}"
  else
    record_result "后端代码检查" "passed" "none" 0
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  init_report
  run_backend_check
  exit ${EXIT_CODE}
fi
