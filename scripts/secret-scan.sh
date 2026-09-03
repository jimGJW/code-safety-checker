#!/usr/bin/env bash
# ==============================================================================
# 敏感信息泄露扫描 (Secret Scan)
# 使用 gitleaks 作为主引擎，trufflehog 为备选，并附加自定义正则扫描
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SCAN_DIR="${SCAN_DIR:-${1:-.}}"
SCAN_DEPTH="${SCAN_DEPTH:-0}"  # 0 = 全历史扫描
REPORT_JSON="${REPORT_DIR}/secret-scan.json"
REPORT_TXT="${REPORT_DIR}/secret-scan.txt"

scan_with_gitleaks() {
  if ! command_exists gitleaks; then
    log_warn "gitleaks 未安装，尝试使用 Docker 运行..."
    if command_exists docker; then
      log_info "使用 Docker 运行 gitleaks..."
      docker run --rm -v "$(pwd):/scan" -w /scan zricethezav/gitleaks:latest \
        detect --source="." --report-path="/scan/${REPORT_JSON}" --no-banner -f json \
        ${SCAN_DEPTH:#0:---log-opts="--max-count=${SCAN_DEPTH}"} 2>/dev/null || true
      # 将报告从容器路径转换为本地路径
      sed -i 's|/scan/||g' "${REPORT_JSON}" 2>/dev/null || true
    else
      log_warn "Docker 也不可用，跳过 gitleaks，改用内置正则扫描"
      return 2
    fi
  else
    log_info "使用本地 gitleaks 扫描..."
    local extra_args=()
    if [[ -f "${CHECKER_ROOT}/config/secret-patterns.json" ]]; then
      # gitleaks 使用 TOML 配置；此处仅启用默认规则
      true
    fi
    gitleaks detect --source="${SCAN_DIR}" --report-path="${REPORT_JSON}" \
      --no-banner -f json ${SCAN_DEPTH:+--log-opts="--max-count=${SCAN_DEPTH}"} 2>/dev/null || true
  fi
  return 0
}

builtin_regex_scan() {
  # 内置正则扫描：遍历项目文件匹配 config/secret-patterns.json
  local patterns_file="${CHECKER_ROOT}/config/secret-patterns.json"
  local result_count=0
  local tmp_output="${REPORT_DIR}/.secret-regex.tmp"
  : > "${tmp_output}"

  if [[ ! -f "$patterns_file" ]]; then
    log_warn "自定义规则文件不存在，跳过正则扫描"
    return 0
  fi

  log_info "运行内置正则扫描引擎..."

  # 直接写死关键模式（避免依赖 jq；并行数组兼容 bash 3.2）
  declare -a PNAME PREG
  PNAME[0]="AWS Access Key";          PREG[0]="AKIA[0-9A-Z]{16}"
  PNAME[1]="GitHub PAT";              PREG[1]="gh[pousr]_[A-Za-z0-9]{36,}"
  PNAME[2]="Private Key";             PREG[2]="-----BEGIN [A-Z ]*PRIVATE KEY-----"
  PNAME[3]="Password Hardcoded";      PREG[3]="(?i)(password|passwd|pwd)\s*[:=]\s*['\"][^'\"]{6,}['\"]"
  PNAME[4]="API Key Hardcoded";       PREG[4]="(?i)(api[_-]?key|apikey|secret[_-]?key)\s*[:=]\s*['\"][A-Za-z0-9_\-]{20,}['\"]"
  PNAME[5]="DB Connection String";    PREG[5]="(?i)(mysql|postgres|mongodb|redis|mssql)://[A-Za-z0-9_\-]+:[A-Za-z0-9_\-]+@"
  PNAME[6]="Bearer Token";            PREG[6]="Bearer\s+[A-Za-z0-9_\-=.]{20,}"
  PNAME[7]="JWT Token";               PREG[7]="eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"
  PNAME[8]="Slack/Discord Webhook";   PREG[8]="https://hooks\.(slack|discord|teams|github)\.com/[A-Za-z0-9_\-/]+"
  PNAME[9]="Google Service Account";  PREG[9]="\"type\"\s*:\s*\"service_account\""

  local exclude_dirs=(
    "node_modules" ".git" "dist" "build" "vendor"
    ".venv" "__pycache__" "target" "bin" "obj"
    ".next" ".nuxt" ".cache" "coverage" ".husky"
  )

  local exclude_files=(
    "*.min.js" "*.min.css" "*.map" "*.png" "*.jpg" "*.jpeg"
    "*.gif" "*.pdf" "*.zip" "*.tar.*" "*.gz" "*.lock"
    "package-lock.json" "yarn.lock" "pnpm-lock.yaml"
    "go.sum" "Cargo.lock" "composer.lock"
    "*.md" "*.example" "*.sample" "*.template"
  )

  local exclude_args=()
  for d in "${exclude_dirs[@]}"; do exclude_args+=("--exclude-dir=$d"); done
  for f in "${exclude_files[@]}"; do exclude_args+=("--exclude=$f"); done

  # 批量扫描：把规则写入临时文件，用 pgrep.py --batch 一次遍历匹配所有规则
  local rules_file batch_file
  rules_file=$(mktemp)
  batch_file=$(mktemp)
  local _pi=0
  while [[ $_pi -lt ${#PNAME[@]} ]]; do
    printf '%s\t%s\n' "${PNAME[$_pi]}" "${PREG[$_pi]}" >> "$rules_file"
    _pi=$((_pi + 1))
  done
  grep_p_batch "$rules_file" "$SCAN_DIR" "${exclude_args[@]}" > "$batch_file" 2>/dev/null || true
  rm -f "$rules_file"

  # 逐条规则从 batch 结果中提取匹配行（IFS=tab 正确切分名称与内容，保留内容中的 tab）
  _pi=0
  while [[ $_pi -lt ${#PNAME[@]} ]]; do
    local pattern_name="${PNAME[$_pi]}"
    local cnt=0
    local out=""
    local name rest
    while IFS=$'\t' read -r name rest; do
      [[ -z "$name" ]] && continue
      [[ "$name" == "$pattern_name" ]] || continue
      cnt=$((cnt + 1))
      [[ $cnt -le 20 ]] && out="${out}${rest}"$'\n'
    done < "$batch_file"
    if [[ $cnt -gt 0 ]]; then
      log_warn "发现 ${cnt} 处疑似 [${pattern_name}]"
      echo "=== ${pattern_name} (${cnt} 处) ===" >> "${tmp_output}"
      printf '%s' "$out" >> "${tmp_output}"
      echo "" >> "${tmp_output}"
      result_count=$((result_count + cnt))
    fi
    _pi=$((_pi + 1))
  done
  rm -f "$batch_file"

  # 输出到报告
  if [[ -s "${tmp_output}" ]]; then
    mv "${tmp_output}" "${REPORT_TXT}"
    # 生成简易 JSON
    if ! command_exists jq; then
      echo "{\"tool\": \"builtin-regex-scan\", \"findings\": ${result_count}}" > "${REPORT_JSON}"
    else
      echo "[]" | jq --argjson c "$result_count" '{tool: "builtin-regex-scan", findings: $c}' > "${REPORT_JSON}"
    fi
  else
    rm -f "${tmp_output}"
    echo "未发现敏感信息泄露。" > "${REPORT_TXT}"
  fi

  echo "$result_count"
}

run_secret_scan() {
  log_step "敏感信息泄露扫描"
  ensure_dir "${REPORT_DIR}"

  local total_findings=0

  # 1. 主引擎：gitleaks
  log_section "引擎 1/3: gitleaks 历史提交扫描"
  local gitleaks_rc=0
  scan_with_gitleaks || gitleaks_rc=$?
  local gitleaks_findings=0
  if [[ -f "${REPORT_JSON}" && -s "${REPORT_JSON}" ]]; then
    if command_exists jq; then
      gitleaks_findings=$(jq 'length' "${REPORT_JSON}" 2>/dev/null || echo 0)
    else
      gitleaks_findings=$(grep -c '"RuleID"' "${REPORT_JSON}" 2>/dev/null || true)
    fi
  fi
  log_info "gitleaks 发现 ${gitleaks_findings} 处问题"

  # 2. 内置正则扫描（作为兜底）
  log_section "引擎 2/3: 内置正则规则扫描"
  local regex_findings
  regex_findings=$(builtin_regex_scan)
  log_info "正则扫描发现 ${regex_findings} 处问题"

  # 3. TruffleHog 可选
  log_section "引擎 3/3: TruffleHog（可选）"
  local trufflehog_findings=0
  if command_exists trufflehog; then
    log_info "TruffleHog 可用，运行中..."
    trufflehog filesystem "${SCAN_DIR}" --no-update --json 2>/dev/null > "${REPORT_DIR}/trufflehog.jsonl" || true
    trufflehog_findings=$(wc -l < "${REPORT_DIR}/trufflehog.jsonl" 2>/dev/null || echo 0)
    log_info "TruffleHog 发现 ${trufflehog_findings} 处问题"
  else
    log_warn "TruffleHog 未安装，已跳过（可手动安装：https://github.com/trufflesecurity/trufflehog）"
  fi

  total_findings=$((gitleaks_findings + regex_findings + trufflehog_findings))

  # 判定结果：任何 high/critical 即失败
  if [[ $total_findings -gt 0 ]]; then
    record_result "敏感信息泄露扫描" "failed" "critical" "${total_findings}" \
      "gitleaks=${gitleaks_findings}, regex=${regex_findings}, trufflehog=${trufflehog_findings}"
    log_error "请查看报告: ${REPORT_TXT} / ${REPORT_JSON}"
    log_error "修复建议: 1) 从仓库历史中彻底移除密钥 (git-filter-repo / BFG) 2) 立即轮换已泄露密钥 3) 使用 .env + .gitignore 管理密钥"
  else
    record_result "敏感信息泄露扫描" "passed" "none" 0
  fi
}

# 脚本直跑支持
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  init_report
  run_secret_scan
  exit ${EXIT_CODE}
fi
