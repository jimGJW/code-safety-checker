#!/usr/bin/env bash
# ==============================================================================
# 许可证合规性检查 (License Compliance)
# 防止引入 GPL/AGPL 等"传染性"许可证导致商业项目法律风险
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SCAN_DIR="${SCAN_DIR:-${1:-.}}"

DEFAULT_BLOCKLIST=("GPL-1.0" "GPL-2.0" "GPL-3.0" "AGPL-1.0" "AGPL-3.0" "SSPL-1.0" "SSPL" "BUSL-1.1")
DEFAULT_ALLOWLIST=(
  "MIT" "MIT-0" "Apache-2.0" "Apache-1.1" "BSD-2-Clause" "BSD-3-Clause"
  "ISC" "Python-2.0" "PSF-2.0" "LGPL-2.1" "LGPL-3.0" "MPL-2.0" "Zlib"
  "Unlicense" "CC0-1.0" "WTFPL" "BlueOak-1.0.0" "0BSD" "BSL-1.0" "PostgreSQL"
  "Ruby" "Artistic-2.0" "EPL-2.0" "OFL-1.1"
)

check_npm_licenses() {
  local issues=0
  [[ -f "${SCAN_DIR}/package.json" ]] || { echo 0; return; }
  log_info "检查 npm 依赖许可证..."

  if command_exists license-checker; then
    license-checker --json --production --out "${REPORT_DIR}/npm-licenses.json" 2>/dev/null || true
  elif [[ -x "${SCAN_DIR}/node_modules/.bin/license-checker" ]]; then
    "${SCAN_DIR}/node_modules/.bin/license-checker" --json --production \
      --out "${REPORT_DIR}/npm-licenses.json" 2>/dev/null || true
  else
    log_warn "license-checker 未安装，使用内置提取 (安装: npm i -g license-checker-rseidelsohn)"
    # 兜底：从 package.json 每个依赖自己的 package.json 读取
    local dep_file="${REPORT_DIR}/npm-licenses.json"
    echo "{}" > "$dep_file"
    if command_exists jq; then
      # 简单抽取所有依赖名称
      local deps
      deps=$(jq -r '.dependencies // {} | keys[]' "${SCAN_DIR}/package.json" 2>/dev/null || true)
      local tmp_obj="{}"
      for d in $deps; do
        local pf="${SCAN_DIR}/node_modules/${d}/package.json"
        if [[ -f "$pf" ]]; then
          local lic
          lic=$(jq -r '.license // (.licenses? // []) | if type=="array" then (map(.type? // .) | join(",")) else . end' "$pf" 2>/dev/null || echo "UNKNOWN")
          tmp_obj=$(echo "$tmp_obj" | jq --arg k "$d" --arg v "$lic" '. + {($k): {"licenses": $v}}')
        fi
      done
      echo "$tmp_obj" > "$dep_file"
    fi
  fi

  # 检查 blocklist
  if command_exists jq && [[ -s "${REPORT_DIR}/npm-licenses.json" ]]; then
    local blocked_json
    blocked_json=$(jq --argjson bl "$(printf '%s\n' "${DEFAULT_BLOCKLIST[@]}" | jq -R . | jq -s .)" '
      to_entries | map(select(.key != "_comment")) |
      map({pkg: .key, lic: (.value.licenses // (.value.license // "UNKNOWN"))}) |
      map(.lic = (if (.lic|type) == "array" then (.lic|map(.type? // .) | join(",")) else .lic end)) |
      map(select([.lic] | inside($bl) == false and ([.lic] | inside($bl | map(. + "+"))) == false ))? |
      map(select(.lic as $l | $bl[] as $b | $l | startswith($b))))
    ' "${REPORT_DIR}/npm-licenses.json" 2>/dev/null || echo "[]")

    issues=$(echo "$blocked_json" | jq 'length')
    if [[ $issues -gt 0 ]]; then
      echo "发现 ${issues} 个阻塞级许可证:" >> "${REPORT_DIR}/license-check.txt"
      echo "$blocked_json" | jq -r '.[] | "  - \(.pkg) => \(.lic)"' >> "${REPORT_DIR}/license-check.txt"
    fi
  else
    # 正则兜底
    for bl in "${DEFAULT_BLOCKLIST[@]}"; do
      local c
      c=$(grep -iE "\"licenses\"\\s*:\\s*\"${bl}\"" "${REPORT_DIR}/npm-licenses.json" 2>/dev/null | wc -l | tr -d ' ')
      issues=$((issues + c))
    done
  fi
  log_info "  → 阻塞级许可证: ${issues}"
  echo "$issues"
}

check_python_licenses() {
  local issues=0
  local marker=0
  [[ -f "${SCAN_DIR}/requirements.txt" || -f "${SCAN_DIR}/pyproject.toml" ]] && marker=1
  [[ $marker -eq 0 ]] && { echo 0; return; }
  log_info "检查 Python 依赖许可证..."

  if command_exists pip-licenses; then
    pip-licenses --format json --output-file "${REPORT_DIR}/pip-licenses.json" 2>/dev/null || true
    if command_exists jq && [[ -s "${REPORT_DIR}/pip-licenses.json" ]]; then
      for bl in "${DEFAULT_BLOCKLIST[@]}"; do
        local c
        c=$(jq --arg b "$bl" '[.[] | select(.License? | startswith($b))] | length' "${REPORT_DIR}/pip-licenses.json" 2>/dev/null || echo 0)
        issues=$((issues + c))
      done
    fi
  else
    log_warn "pip-licenses 未安装，跳过 (pip install pip-licenses)"
  fi
  echo "$issues"
}

run_license_check() {
  log_step "许可证合规性检查"
  ensure_dir "${REPORT_DIR}"
  : > "${REPORT_DIR}/license-check.txt"

  local npm_py="${DEFAULT_BLOCKLIST[@]}"
  local npm_issues=0
  local pip_issues=0

  npm_issues=$(check_npm_licenses)
  pip_issues=$(check_python_licenses)

  local total=$((npm_issues + pip_issues))
  log_info "阻塞级许可证总数: ${total} (npm=${npm_issues}, pip=${pip_issues})"

  if [[ $total -gt 0 ]]; then
    record_result "许可证合规检查" "failed" "high" "$total" \
      "GPL/AGPL/SSPL 等许可证具有传染性，商业闭源项目不可直接使用"
    log_error "请查看 ${REPORT_DIR}/license-check.txt"
    log_error "修复建议: 1) 寻找 MIT/Apache-2.0 替代包 2) 确认项目 license 与使用场景是否匹配 3) 咨询法务"
  else
    record_result "许可证合规检查" "passed" "none" 0
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  init_report
  run_license_check
  exit ${EXIT_CODE}
fi
