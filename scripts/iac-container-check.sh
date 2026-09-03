#!/usr/bin/env bash
# ==============================================================================
# 基础设施即代码 (IaC) 与容器镜像安全检查
# 覆盖: Dockerfile / Docker Compose / Terraform / Kubernetes YAML / Helm
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

SCAN_DIR="${SCAN_DIR:-${1:-.}}"
REPORT_DIR="${REPORT_DIR:-${CHECKER_ROOT}/reports}"

# bash 3.2 兼容：用独立计数器替代关联数组
SEV_HIGH=0
SEV_CRITICAL=0
SEV_MEDIUM=0

# ---- Dockerfile 最佳实践检查 (内置零依赖) ----
check_dockerfile_builtin() {
  local issues=0
  : > "${REPORT_DIR}/dockerfile-check.txt"

  local dockerfiles=()
  while IFS= read -r f; do
    dockerfiles+=("$f")
  done < <(find "${SCAN_DIR}" -name "Dockerfile*" -not -path "*/node_modules/*" 2>/dev/null)

  [[ ${#dockerfiles[@]} -eq 0 ]] && { echo "0|0"; return; }
  log_info "发现 ${#dockerfiles[@]} 个 Dockerfile"

  for df in "${dockerfiles[@]}"; do
    local name_count=0
    # 1. latest tag / 无版本 tag
    local from_lines
    from_lines=$(grep -inE '^FROM' "$df" || true)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if echo "$line" | grep -qE ':(latest|[a-zA-Z_]+$)'; then
        echo "$df: 不推荐使用 latest/不稳定基础镜像 -> $line" >> "${REPORT_DIR}/dockerfile-check.txt"
        issues=$((issues + 1))
      fi
    done <<< "$from_lines"

    # 2. root 用户运行
    if ! grep -qiE '^USER[^ ]' "$df"; then
      echo "$df: 未切换非 root 用户 (缺少 USER 指令)" >> "${REPORT_DIR}/dockerfile-check.txt"
      issues=$((issues + 1))
    fi

    # 3. ADD 远端 tarball / URL 风险
    if grep -qE '^ADD\s+(https?://|\s+)' "$df" 2>/dev/null; then
      echo "$df: 使用 ADD 可能引入不可变/未校验资源 (建议用 COPY + RUN curl)" >> "${REPORT_DIR}/dockerfile-check.txt"
      issues=$((issues + 1))
    fi

    # 4. 暴露过多端口
    local expose_count
    expose_count=$(grep -cE '^EXPOSE' "$df" 2>/dev/null || true)
    if [[ $expose_count -gt 5 ]]; then
      echo "$df: EXPOSE 端口过多 (${expose_count})，请确认是否都需要" >> "${REPORT_DIR}/dockerfile-check.txt"
      issues=$((issues + 1))
    fi

    # 5. 在 Dockerfile 中写入密钥
    if grep -qiE '(secret|password|token|api[_-]?key|ssh_prv_key).*=|ARG.*(SECRET|PASSWORD|TOKEN|KEY)' "$df"; then
      echo "$df: 疑似 Dockerfile 中硬编码/传递密钥 (请使用 BuildKit secrets / 环境变量)" >> "${REPORT_DIR}/dockerfile-check.txt"
      SEV_HIGH=$((SEV_HIGH + 1))
      issues=$((issues + 1))
    fi

    # 6. 缺少 HEALTHCHECK
    if ! grep -qiE '^HEALTHCHECK' "$df"; then
      echo "$df: 缺少 HEALTHCHECK，容器 orchestrator 无法健康探测" >> "${REPORT_DIR}/dockerfile-check.txt"
      issues=$((issues + 1))
    fi

    # 7. 未固定 apt 包版本
    if grep -iE 'apt-get install|yum install|apk add' "$df" | grep -qvE '(--no-cache|=|-[0-9]+)' | head -1 | grep -q .; then
      echo "$df: 包管理器安装未固定版本，导致镜像构建不可重现" >> "${REPORT_DIR}/dockerfile-check.txt"
      issues=$((issues + 1))
    fi
  done

  echo "${issues}|${SEV_HIGH}"
}

# ---- Terraform / K8s / Helm 内置规则 ----
check_iac_builtin() {
  local issues=0
  : > "${REPORT_DIR}/iac-check.txt"

  # 1. Terraform
  local tf_count
  tf_count=$(find "${SCAN_DIR}" -name "*.tf" -not -path "*/node_modules/*" -not -path "*/.terraform/*" 2>/dev/null | wc -l | tr -d ' ')
  if [[ $tf_count -gt 0 ]]; then
    log_info "发现 ${tf_count} 个 Terraform 文件"
    # AWS Security Group 0.0.0.0/0
    local hits
    hits=$(grep -rnE 'cidr_blocks[[:space:]]*=[[:space:]]*\[[[:space:]]*"0\.0\.0\.0/0"' "${SCAN_DIR}" --include="*.tf" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
      local c
      c=$(echo "$hits" | wc -l | tr -d ' ')
      echo "Terraform: 发现 ${c} 处 Security Group 开放 0.0.0.0/0" >> "${REPORT_DIR}/iac-check.txt"
      echo "$hits" >> "${REPORT_DIR}/iac-check.txt"
      SEV_HIGH=$((SEV_HIGH + c))
      issues=$((issues + c))
    fi
    # S3 未加密 / public
    hits=$(grep -rnE 'bucket.*=.*"(public|"[a-z0-9-]+")' "${SCAN_DIR}" --include="*.tf" 2>/dev/null | grep -i public || true)
    # 加密
    local enc
    enc=$(grep -rnL 'server_side_encryption_configuration\|sse_algorithm\s*=\s*"AES256"\|sse_algorithm\s*=\s*"aws:kms"' "${SCAN_DIR}"/*.tf 2>/dev/null || true)
    if [[ -n "$enc" ]]; then
      local c2
      c2=$(echo "$enc" | wc -l | tr -d ' ')
      echo "Terraform: ${c2} 个 S3 bucket 未显式启用服务端加密" >> "${REPORT_DIR}/iac-check.txt"
      issues=$((issues + c2))
    fi
  fi

  # 2. Kubernetes YAML
  local k8s_files=()
  while IFS= read -r f; do
    k8s_files+=("$f")
  done < <(grep -rlE '^apiVersion:' "${SCAN_DIR}" --include="*.yaml" --include="*.yml" 2>/dev/null | head -200)

  if [[ ${#k8s_files[@]} -gt 0 ]]; then
    log_info "发现 ${#k8s_files[@]} 个 Kubernetes YAML 文件"

    # 特权容器
    local hits
    hits=$(grep -InH 'privileged:\s*true' "${k8s_files[@]}" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
      local c
      c=$(echo "$hits" | wc -l | tr -d ' ')
      echo "K8s: 发现 ${c} 处 privileged: true (高危)" >> "${REPORT_DIR}/iac-check.txt"
      SEV_CRITICAL=$((SEV_CRITICAL + c))
      issues=$((issues + c))
    fi

    # runAsRoot 允许
    hits=$(grep -InH 'runAsNonRoot:\s*false' "${k8s_files[@]}" 2>/dev/null || true)
    [[ -n "$hits" ]] && {
      local c; c=$(echo "$hits" | wc -l | tr -d ' ')
      echo "K8s: ${c} 处允许以 root 运行" >> "${REPORT_DIR}/iac-check.txt"
      SEV_HIGH=$((SEV_HIGH + c))
      issues=$((issues + c))
    }

    # latest tag
    hits=$(grep -InE 'image:.*:latest|image:[^:]*$' "${k8s_files[@]}" 2>/dev/null || true)
    [[ -n "$hits" ]] && {
      local c; c=$(echo "$hits" | wc -l | tr -d ' ')
      echo "K8s: ${c} 处镜像使用 latest tag / 无 tag" >> "${REPORT_DIR}/iac-check.txt"
      issues=$((issues + c))
    }

    # 资源限制
    local no_limits=0
    for f in "${k8s_files[@]}"; do
      if grep -qE 'kind:\s*Deployment|kind:\s*StatefulSet|kind:\s*DaemonSet|kind:\s*CronJob' "$f" 2>/dev/null; then
        if ! grep -qE 'resources:' "$f" 2>/dev/null; then
          no_limits=$((no_limits + 1))
        else
          # 检查 resources 下是否有 limits
          local in_resources=0
          local found_limits=0
          while IFS= read -r line; do
            if echo "$line" | grep -qE '^\s*resources:'; then in_resources=1; continue; fi
            if [[ $in_resources -eq 1 ]]; then
              if echo "$line" | grep -qE '^\s*limits:'; then found_limits=1; break; fi
              if echo "$line" | grep -qE '^\s*[A-Za-z]'; then break; fi
            fi
          done < "$f"
          [[ $found_limits -eq 0 ]] && no_limits=$((no_limits + 1))
        fi
      fi
    done
    if [[ $no_limits -gt 0 ]]; then
      echo "K8s: ${no_limits} 个工作负载未配置 resources.limits (容易 OOMKill / 资源耗尽)" >> "${REPORT_DIR}/iac-check.txt"
      issues=$((issues + no_limits))
    fi
  fi

  echo "${issues}"
}

# ---- 容器镜像扫描 (Trivy) ----
scan_container_image() {
  local issues=0
  log_section "容器镜像扫描 (Trivy)"

  # 读取镜像名（优先从环境变量 IMAGE_NAME）
  local image="${IMAGE_NAME:-}"
  if [[ -z "$image" ]]; then
    # 若本地已有 build 产物，尝试从 Dockerfile 猜测并构建（可选且慢）
    log_warn "未提供 IMAGE_NAME 环境变量，跳过镜像漏洞扫描。"
    log_info "提示: CI 中请先 docker build -t myapp:ci-test . && export IMAGE_NAME=myapp:ci-test"
    echo "0|0"
    return
  fi

  if command_exists trivy; then
    trivy image --exit-code 0 --severity HIGH,CRITICAL --format json \
      -o "${REPORT_DIR}/trivy-image.json" --no-progress "$image" 2>/dev/null || true
    if command_exists jq && [[ -s "${REPORT_DIR}/trivy-image.json" ]]; then
      SEV_HIGH=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "${REPORT_DIR}/trivy-image.json" 2>/dev/null || echo 0)
      SEV_CRITICAL=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "${REPORT_DIR}/trivy-image.json" 2>/dev/null || echo 0)
      issues=$((SEV_HIGH + SEV_CRITICAL))
    fi
    log_info "Trivy: HIGH=${SEV_HIGH}, CRITICAL=${SEV_CRITICAL}"
  elif command_exists docker; then
    log_info "尝试通过 Docker 运行 aquasec/trivy..."
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
      -v "${REPORT_DIR}:/reports" aquasec/trivy:latest image --exit-code 0 \
      --severity HIGH,CRITICAL --format json -o /reports/trivy-image.json "$image" 2>/dev/null || true
    issues=0
  else
    log_warn "Trivy 未安装且无 Docker，跳过镜像扫描 (https://github.com/aquasecurity/trivy)"
  fi
  echo "${issues}|${SEV_CRITICAL}"
}

run_iac_container_check() {
  log_step "IaC (Dockerfile/Terraform/K8s) 与容器镜像检查"
  ensure_dir "${REPORT_DIR}"

  local docker_part iac_issues image_part
  docker_part=$(check_dockerfile_builtin)           # issues|high
  iac_issues=$(check_iac_builtin)                   # issues
  image_part=$(scan_container_image)                # issues|critical

  local docker_issues="${docker_part%|*}"
  local image_issues="${image_part%|*}"
  local critical="${image_part##*|}"
  local total=$((docker_issues + iac_issues + image_issues))

  log_info "汇总: Dockerfile=${docker_issues}, IaC=${iac_issues}, 镜像=${image_issues} (critical=${critical})"

  if [[ ${SEV_CRITICAL} -gt 0 ]]; then
    record_result "IaC/容器检查" "failed" "critical" "$total" "Critical=${SEV_CRITICAL}, High=${SEV_HIGH}"
  elif [[ $total -gt 0 ]]; then
    record_result "IaC/容器检查" "failed" "medium" "$total" "High=${SEV_HIGH}"
  else
    record_result "IaC/容器检查" "passed" "none" 0
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  init_report
  run_iac_container_check
  exit ${EXIT_CODE}
fi
