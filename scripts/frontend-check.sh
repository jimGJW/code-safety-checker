#!/usr/bin/env bash
# ==============================================================================
# 前端代码安全与质量检查 (Frontend Security & Quality)
# 检测 XSS、eval、硬编码密钥、未转义 HTML、CSP 问题、npm 脚本命令注入等
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SCAN_DIR="${1:-.}"
REPORT_TXT="${REPORT_DIR}/frontend-check.txt"

# 前端源码典型目录
FRONTEND_SRC_DIRS=("src" "app" "pages" "components" "lib" "utils" "hooks" "views" "client" "web")
FRONTEND_EXTENSIONS=("js" "jsx" "ts" "tsx" "vue" "svelte" "astro" "html" "htm")

find_frontend_files() {
  local result=()
  # 构造 extension 参数
  local ext_args=()
  for ext in "${FRONTEND_EXTENSIONS[@]}"; do
    ext_args+=("-name" "*.${ext}" "-o")
  done
  unset 'ext_args[${#ext_args[@]}-1]'  # 移除最后的 -o

  for subdir in "." "${FRONTEND_SRC_DIRS[@]}"; do
    local target="${SCAN_DIR}/${subdir}"
    [[ -d "$target" ]] || continue
    while IFS= read -r -d '' f; do
      result+=("$f")
    done < <(find "$target" -type f \( "${ext_args[@]}" \) \
      ! -path "*/node_modules/*" \
      ! -path "*/dist/*" \
      ! -path "*/build/*" \
      ! -path "*/.next/*" \
      ! -path "*/.nuxt/*" \
      ! -path "*/coverage/*" \
      ! -name "*.min.js" -print0 2>/dev/null)
  done
  # 去重 & 输出
  printf "%s\n" "${result[@]}" | sort -u
}

run_eslint() {
  local issues=0
  log_section "运行 ESLint（若项目已配置）"

  if [[ -f "${SCAN_DIR}/package.json" ]] && (grep -q '"eslint"' "${SCAN_DIR}/package.json" 2>/dev/null || [[ -f "${SCAN_DIR}/.eslintrc"* || -f "${SCAN_DIR}/eslint.config"* ]]); then
    # 检查本地 eslint 是否安装
    local eslint_bin=""
    if [[ -x "${SCAN_DIR}/node_modules/.bin/eslint" ]]; then
      eslint_bin="${SCAN_DIR}/node_modules/.bin/eslint"
    elif command_exists eslint; then
      eslint_bin="eslint"
    fi

    if [[ -n "$eslint_bin" ]]; then
      local eslint_report="${REPORT_DIR}/eslint-report.json"
      ($eslint_bin . --ext .js,.jsx,.ts,.tsx,.vue --format json --no-error-on-unmatched-pattern > "${eslint_report}" 2>/dev/null || true)
      if command_exists jq && [[ -s "${eslint_report}" ]]; then
        # 统计 error 级别的问题
        issues=$(jq '[.[] | .errorCount] | add // 0' "${eslint_report}" 2>/dev/null || echo 0)
        local warns
        warns=$(jq '[.[] | .warningCount] | add // 0' "${eslint_report}" 2>/dev/null || echo 0)
        log_info "ESLint: errors=${issues}, warnings=${warns}"
      else
        issues=$(grep -oE '"errorCount"\s*:\s*[0-9]+' "${eslint_report}" 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
      fi
    else
      log_warn "项目有 ESLint 配置但未安装 eslint 依赖，跳过"
    fi
  else
    log_warn "未检测到 ESLint 配置，跳过 ESLint 运行"
  fi
  echo "$issues"
}

run_semgrep_frontend() {
  local issues=0
  log_section "运行 Semgrep 前端安全规则（降级：内置规则实现）"

  if command_exists semgrep; then
    local report="${REPORT_DIR}/semgrep-frontend.json"
    semgrep --config=p/javascript --config=p/typescript --config=p/xss \
      --json --output="${report}" --quiet \
      --exclude=node_modules --exclude=dist --exclude=build \
      "${SCAN_DIR}" 2>/dev/null || true
    if command_exists jq && [[ -s "${report}" ]]; then
      issues=$(jq '.results | length' "${report}" 2>/dev/null || echo 0)
    fi
  else
    log_warn "Semgrep 未安装，使用内置规则代替"
    issues=$(run_builtin_frontend_rules)
  fi
  echo "$issues"
}

run_builtin_frontend_rules() {
  # 内置前端安全规则（grep 实现，零依赖）
  local issues=0
  declare -a frontend_files
  mapfile -t frontend_files < <(find_frontend_files)
  local total_files="${#frontend_files[@]}"
  log_info "扫描前端源文件: ${total_files} 个"

  if [[ $total_files -eq 0 ]]; then
    echo "0"
    return
  fi

  : > "${REPORT_TXT}.rules.tmp"

  declare -A RULES=(
    ["XSS: 危险的 innerHTML/outerHTML 赋值"]="\.(innerHTML|outerHTML)\s*="
    ["XSS: document.write 注入"]="document\.write\s*\("
    ["XSS: React dangerouslySetInnerHTML"]="dangerouslySetInnerHTML"
    ["XSS: Vue v-html 指令"]="v-html\s*="
    ["代码注入: eval() 调用"]="eval\s*\("
    ["代码注入: new Function()"]="new\s+Function\s*\("
    ["代码注入: setTimeout/setInterval 字符串形式"]="set(Timeout|Interval)\s*\(\s*['\"]"
    ["代码注入: setTimeout/setInterval 字符串形式"]="set(Timeout|Interval)\s*\(\s*`"
    ["DOM 型 XSS: location.hash 未过滤直接使用"]="location\.hash[^;]*innerHTML|location\.hash[^;]*\.replace\(|location\.hash[^;]*eval"
    ["敏感数据: localStorage/sessionStorage 存明文密码/JWT"]="(localStorage|sessionStorage)\.setItem\([^)]*(password|token|jwt|secret)"
    ["不安全跳转: 直接使用用户可控 URL"]="window\.location\s*=\s*(req\.|params\.|query\.|props\.|userInput|location\.search)"
    ["硬编码密钥模式"]="(api[_-]?key|apikey|secret|access[_-]?token|private[_-]?key)\s*[:=]\s*['\"][A-Za-z0-9_\-]{15,}['\"]"
    ["CSP: 允许 unsafe-eval/unsafe-inline (meta 标签)"]="Content-Security-Policy[^>]*unsafe-(eval|inline)"
    ["SQL 拼接: 前端直接构造 SQL"]="SELECT\s+.*\$\{|INSERT\s+.*\$\{|UPDATE\s+.*\$\{"
    ["命令注入: Nodejs child_process.exec 用户输入拼接"]="exec(FileSync)?\s*\(\s*`.*\$\{|exec\s*\(\s*['\"][^'\"]*\$\{"
  )

  local files_list_file
  files_list_file=$(mktemp)
  printf "%s\n" "${frontend_files[@]}" > "$files_list_file"

  for rule_name in "${!RULES[@]}"; do
    local pattern="${RULES[$rule_name]}"
    local hits
    hits=$(grep -InHP "$pattern" -f <(cat "$files_list_file") "${SCAN_DIR}" 2>/dev/null | head -50 || true)
    # 兼容无 xargs -f 的系统，改用 xargs
    if [[ -z "$hits" ]]; then
      hits=$(xargs grep -InHP "$pattern" < "$files_list_file" 2>/dev/null | head -50 || true)
    fi
    if [[ -n "$hits" ]]; then
      local count
      count=$(echo "$hits" | wc -l | tr -d ' ')
      echo "【${rule_name}】发现 ${count} 处:" >> "${REPORT_TXT}.rules.tmp"
      echo "$hits" >> "${REPORT_TXT}.rules.tmp"
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

check_frontend_reliability() {
  # 可靠性/代码质量检查（大文件、超长函数、测试覆盖率提示）
  local issues=0
  local warn_only=0
  declare -a frontend_files
  mapfile -t frontend_files < <(find_frontend_files)

  log_section "前端可靠性 / 代码质量检查"

  # 1. 文件行数
  for f in "${frontend_files[@]}"; do
    local lines
    lines=$(wc -l < "$f" 2>/dev/null || echo 0)
    if [[ $lines -gt 500 ]]; then
      echo "WARN: 超大文件 ${f} (${lines} 行 > 500)" >> "${REPORT_DIR}/frontend-reliability.txt" 2>/dev/null || true
      warn_only=$((warn_only + 1))
    fi
  done

  # 2. console.log 残留（提示级别，不阻塞）
  local console_count
  console_count=$(grep -rInH "console\.log\|console\.warn\|console\.error" "${frontend_files[@]}" 2>/dev/null | wc -l | tr -d ' ')
  log_info "console.* 残留: ${console_count} 处（生产环境建议移除/禁用）"

  # 3. package.json 安全审计（preinstall 等生命周期脚本风险）
  if [[ -f "${SCAN_DIR}/package.json" ]]; then
    local life_cycle_scripts
    life_cycle_scripts=$(grep -nE '"(preinstall|install|postinstall|prepublish|prepare)"' "${SCAN_DIR}/package.json" 2>/dev/null || true)
    if [[ -n "$life_cycle_scripts" ]]; then
      local count
      count=$(echo "$life_cycle_scripts" | wc -l | tr -d ' ')
      log_warn "package.json 中包含 ${count} 个 install 生命周期钩子脚本（供应链风险）"
      echo "${life_cycle_scripts}" >> "${REPORT_DIR}/frontend-reliability.txt" 2>/dev/null || true
      issues=$((issues + count))
    fi
    # 4. 依赖 pinning 检查（非固定版本 "^x.y.z" / ">=x" 可能带来不稳定）
    local unpinned
    unpinned=$(grep -nE '"[a-zA-Z@][^"]*"\s*:\s*"[\^~><=]' "${SCAN_DIR}/package.json" 2>/dev/null | wc -l | tr -d ' ')
    log_info "未固定版本号的依赖: ${unpinned} 个（建议 lockfile + --frozen-lockfile 安装）"
  fi

  log_info "可靠性提示项: ${warn_only} 个（不阻塞 MR）, 风险项: ${issues} 个（将阻塞）"
  echo "${issues}"
}

run_frontend_check() {
  log_step "前端代码安全与可靠性检查"
  ensure_dir "${REPORT_DIR}"

  # 自动检测是否有前端代码
  local frontend_marker=""
  [[ -f "${SCAN_DIR}/package.json" ]] && frontend_marker="package.json"
  local any_frontend
  any_frontend=$(find_frontend_files | wc -l | tr -d ' ')

  if [[ -z "${frontend_marker}" && "$any_frontend" -eq 0 ]]; then
    record_result "前端代码检查" "skipped" "none" 0 "未检测到前端代码"
    return
  fi

  log_info "检测到前端项目，开始扫描 (${any_frontend} 个源文件)..."

  local eslint_issues=0
  local semgrep_issues=0
  local reliability_issues=0

  eslint_issues=$(run_eslint)
  semgrep_issues=$(run_semgrep_frontend)
  reliability_issues=$(check_frontend_reliability)

  local total=$((eslint_issues + semgrep_issues + reliability_issues))
  log_info "前端总问题: eslint=${eslint_issues}, 安全规则=${semgrep_issues}, 可靠性=${reliability_issues}"

  if [[ $semgrep_issues -gt 0 ]]; then
    record_result "前端代码检查" "failed" "high" "$total" "安全类问题 ${semgrep_issues} 处"
    log_error "请查看报告: ${REPORT_TXT}"
    log_error "常见修复建议:"
    log_error "  - XSS: 用 textContent 替代 innerHTML；或使用 DOMPurify 清洗 HTML"
    log_error "  - eval/new Function: 用 JSON.parse / 显式分支逻辑替代"
    log_error "  - 密钥: 移到 .env / 服务端环境变量，历史提交用 git-filter-repo 清理"
    log_error "  - React/Vue: 不要直接使用 v-html / dangerouslySetInnerHTML"
  elif [[ $eslint_issues -gt 0 || $reliability_issues -gt 0 ]]; then
    record_result "前端代码检查" "failed" "medium" "$total" "ESLint errors=${eslint_issues}, 可靠性=${reliability_issues}"
  else
    record_result "前端代码检查" "passed" "none" 0
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  init_report
  run_frontend_check
  exit ${EXIT_CODE}
fi
