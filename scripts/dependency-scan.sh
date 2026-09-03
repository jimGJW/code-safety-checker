#!/usr/bin/env bash
# ==============================================================================
# 依赖漏洞检查 (Dependency Vulnerability Scan)
# 支持 npm / yarn / pnpm / pip / go / mvn / gradle 生态
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SCAN_DIR="${1:-.}"
REPORT_DIR="${REPORT_DIR:-${CHECKER_ROOT}/reports}"

scan_npm_deps() {
  local dir="$1"
  local report="${REPORT_DIR}/npm-audit.json"
  local issues=0
  local high_critical=0

  if [[ ! -f "${dir}/package.json" ]]; then
    echo "0"
    return
  fi

  log_info "扫描 npm / yarn / pnpm 依赖..."

  local package_manager="npm"
  [[ -f "${dir}/pnpm-lock.yaml" ]] && package_manager="pnpm"
  [[ -f "${dir}/yarn.lock" ]] && package_manager="yarn"
  log_info "检测到包管理器: ${package_manager}"

  case "$package_manager" in
    pnpm)
      if command_exists pnpm; then
        pnpm audit --json > "${report}" 2>/dev/null || true
      else
        (cd "$dir" && npm audit --json --package-lock-only > "${report}" 2>/dev/null || true)
      fi
      ;;
    yarn)
      if command_exists yarn; then
        # yarn 1.x audit 输出略有不同
        yarn audit --json 2>/dev/null | awk '/^{.*}$/' > "${report}" || true
        [[ ! -s "${report}" ]] && echo '{}' > "${report}"
      else
        (cd "$dir" && npm audit --json --package-lock-only > "${report}" 2>/dev/null || true)
      fi
      ;;
    npm|*)
      (cd "$dir" && npm audit --json --package-lock-only > "${report}" 2>/dev/null || true)
      ;;
  esac

  if command_exists jq && [[ -s "${report}" ]]; then
    issues=$(jq '[.. | objects | select(.severity? != null)] | length' "${report}" 2>/dev/null || echo 0)
    high_critical=$(jq '[.. | objects | select(.severity? == "high" or .severity? == "critical")] | length' "${report}" 2>/dev/null || echo 0)
  else
    # 不依赖 jq 的兜底统计
    issues=$(grep -oE '"severity"\s*:\s*"(low|moderate|high|critical)"' "${report}" 2>/dev/null | wc -l | tr -d ' ')
    high_critical=$(grep -oE '"severity"\s*:\s*"(high|critical)"' "${report}" 2>/dev/null | wc -l | tr -d ' ')
  fi

  log_info "  → 总漏洞数: ${issues}, 高危+严重: ${high_critical}"
  echo "${issues}|${high_critical}"
}

scan_python_deps() {
  local dir="$1"
  local report="${REPORT_DIR}/pip-audit.json"
  local issues=0
  local high_critical=0

  if [[ ! -f "${dir}/requirements.txt" && ! -f "${dir}/pyproject.toml" && ! -f "${dir}/Pipfile" ]]; then
    echo "0|0"
    return
  fi

  log_info "扫描 Python 依赖..."

  if command_exists pip-audit; then
    if [[ -f "${dir}/requirements.txt" ]]; then
      pip-audit -r "${dir}/requirements.txt" --format json > "${report}" 2>/dev/null || true
    elif [[ -f "${dir}/Pipfile" ]]; then
      pip-audit --format json > "${report}" 2>/dev/null || true
    else
      pip-audit --format json > "${report}" 2>/dev/null || true
    fi
    if command_exists jq && [[ -s "${report}" ]]; then
      issues=$(jq '[.dependencies[].vulns[]?] | length' "${report}" 2>/dev/null || echo 0)
      high_critical=$(jq '[.dependencies[].vulns[]? | select(.fix_versions? != null)] | length' "${report}" 2>/dev/null || echo 0)
    fi
  elif command_exists safety; then
    safety check --json > "${report}" 2>/dev/null || true
    if command_exists jq && [[ -s "${report}" ]]; then
      issues=$(jq '.vulnerabilities | length' "${report}" 2>/dev/null || echo 0)
    fi
  else
    log_warn "pip-audit / safety 未安装，跳过 Python 依赖检查。安装: pip install pip-audit"
  fi

  log_info "  → 总漏洞数: ${issues}, 严重: ${high_critical}"
  echo "${issues}|${high_critical}"
}

scan_go_deps() {
  local dir="$1"
  local issues=0

  if [[ ! -f "${dir}/go.mod" ]]; then
    echo "0|0"
    return
  fi

  log_info "扫描 Go 依赖 (govulncheck)..."

  if command_exists govulncheck; then
    (cd "$dir" && govulncheck ./... > "${REPORT_DIR}/go-vulncheck.txt" 2>&1 || true)
    # govulncheck 会输出 "Your code is affected by X vulnerabilities"
    issues=$(grep -oE "affected by [0-9]+ vulnerabilities?" "${REPORT_DIR}/go-vulncheck.txt" 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo 0)
  elif command_exists go; then
    log_warn "govulncheck 未安装，降级为 go list -m 漏洞提示"
    (cd "$dir" && go list -m -json all > "${REPORT_DIR}/go-modules.json" 2>/dev/null || true)
    issues=0
  else
    log_warn "Go 工具链不可用，跳过"
  fi

  log_info "  → 漏洞数: ${issues}"
  echo "${issues}|${issues}"
}

scan_java_deps() {
  local dir="$1"
  local issues=0
  local report="${REPORT_DIR}/mvn-dependency-check.txt"

  if [[ ! -f "${dir}/pom.xml" && ! -f "${dir}/build.gradle" && ! -f "${dir}/build.gradle.kts" ]]; then
    echo "0|0"
    return
  fi

  log_info "扫描 Java 依赖..."

  if [[ -f "${dir}/pom.xml" ]] && command_exists mvn; then
    (cd "$dir" && mvn org.owasp:dependency-check-maven:check -DskipTests -q > "${report}" 2>&1 || true)
    issues=$(grep -oE "[0-9]+ vulnerabilities?" "${report}" 2>/dev/null | grep -oE "[0-9]+" | tail -1 || echo 0)
  elif [[ -f "${dir}/build.gradle" ]] && command_exists gradle; then
    (cd "$dir" && gradle dependencyCheckAnalyze -q > "${report}" 2>&1 || true)
    issues=$(grep -oE "[0-9]+ vulnerabilities?" "${report}" 2>/dev/null | grep -oE "[0-9]+" | tail -1 || echo 0)
  else
    log_warn "mvn/gradle 或 OWASP dependency-check 未配置，跳过"
  fi

  log_info "  → 漏洞数: ${issues}"
  echo "${issues}|${issues}"
}

run_dependency_scan() {
  log_step "依赖漏洞检查"
  ensure_dir "${REPORT_DIR}"

  local total_issues=0
  local total_high=0
  local part=""

  # Node.js 前端/后端
  part=$(scan_npm_deps "${SCAN_DIR}")
  total_issues=$((total_issues + ${part%|*}))
  total_high=$((total_high + ${part##*|}))

  # Python
  part=$(scan_python_deps "${SCAN_DIR}")
  total_issues=$((total_issues + ${part%|*}))
  total_high=$((total_high + ${part##*|}))

  # Go
  part=$(scan_go_deps "${SCAN_DIR}")
  total_issues=$((total_issues + ${part%|*}))
  total_high=$((total_high + ${part##*|}))

  # Java
  part=$(scan_java_deps "${SCAN_DIR}")
  total_issues=$((total_issues + ${part%|*}))
  total_high=$((total_high + ${part##*|}))

  log_info "漏洞汇总：总数 ${total_issues}，高危+严重 ${total_high}"

  if [[ $total_high -gt 0 ]]; then
    record_result "依赖漏洞检查" "failed" "high" "${total_issues}" \
      "高危以上 ${total_high} 个，请立即升级或寻找替代包"
    log_error "修复建议:"
    log_error "  1) 运行 npm audit fix / pnpm audit fix / yarn-audit-fix"
    log_error "  2) 手动升级 package.json 中对应版本"
    log_error "  3) Python: pip-audit --fix; Java: mvn versions:use-latest-versions"
    log_error "  4) 无法升级时，评估是否真的触达漏洞代码路径 (vuln reachability)"
  elif [[ $total_issues -gt 0 ]]; then
    record_result "依赖漏洞检查" "failed" "medium" "${total_issues}" \
      "中低危漏洞 ${total_issues} 个，请规划版本升级"
  else
    record_result "依赖漏洞检查" "passed" "none" 0
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  init_report
  run_dependency_scan
  exit ${EXIT_CODE}
fi
