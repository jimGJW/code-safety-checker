#!/usr/bin/env bash
# ==============================================================================
# gitee-comment.sh —— Gitee 流水线（Gitee Go）中调用 Gitee OpenAPI 的工具脚本
#
# 功能:
#   1) comment-pr          给指定 PR（合并请求）发一条评论
#   2) commit-state        给指定 commit 写一个状态（pending / success / failure）
#
# 前提（Gitee 仓库设置里做一次即可）:
#   - 在 https://gitee.com/profile/personal_access_tokens 创建「私人令牌」
#     权限建议：projects、pull_requests、notes、user_info
#   - 在仓库 → 管理 → 流水线变量（Environment Variables / Secrets）
#     新增一条变量: GITEE_TOKEN=<你的私人令牌>
#
# 用法:
#   ./scripts/gitee-comment.sh comment-pr  <pr_number> "<md_body_file_or_text>"
#   ./scripts/gitee-comment.sh commit-state <commit_sha> <pending|success|failure> [描述]
#
# 注: GITEE_TOKEN / GITEE_OWNER / GITEE_REPO 优先从环境变量读取，
#     未设置时则尝试从 Gitee 注入的流水线默认变量（如 GITEE_PRS_REPO、GITEE_OWNER）推导。
# ==============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITEE_ENDPOINT="${GITEE_ENDPOINT:-https://gitee.com/api/v5}"
GITEE_TOKEN="${GITEE_TOKEN:-}"

log()   { echo "[gitee-api] $*" >&2; }
die()   { echo "[gitee-api][FATAL] $*" >&2; exit 2; }

# ---------- 从环境变量推导 owner / repo ----------
derive_owner_repo() {
  if [[ -n "$GITEE_OWNER" && -n "$GITEE_REPO" ]]; then return 0; fi

  # Gitee Go 会注入一些环境变量（GITEE_REPO、GITEE_OWNER、GITEE_PRS_REPO 等）
  if [[ -z "$GITEE_OWNER" ]]; then
    GITEE_OWNER="${GITEE_PRS_OWNER:-${GITEE_PUSH_OWNER:-}}"
  fi
  if [[ -z "$GITEE_REPO" ]]; then
    GITEE_REPO="${GITEE_PRS_REPO:-${GITEE_PUSH_REPO:-${GITEE_REPO_NAME:-}}}"
  fi

  # 从 git remote 推导（兜底）
  if [[ -z "$GITEE_OWNER" || -z "$GITEE_REPO" ]]; then
    local url
    url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "$url" == *gitee.com* ]]; then
      local s="${url#*gitee.com[/:]}"
      s="${s%.git}"; s="${s%/}"
      GITEE_OWNER="${GITEE_OWNER:-$(dirname "$s")}"
      GITEE_REPO="${GITEE_REPO:-$(basename "$s")}"
    fi
  fi

  [[ -z "$GITEE_OWNER" || -z "$GITEE_REPO" ]] && \
    die "无法推导 GITEE_OWNER / GITEE_REPO，请手动导出这两个变量"
  true
}

ensure_token() {
  [[ -z "$GITEE_TOKEN" ]] && die "缺少 GITEE_TOKEN 环境变量（Gitee 私人令牌）；请在 Gitee 仓库 → 管理 → 流水线变量 中新增 GITEE_TOKEN"
}

curl_cmd() {
  # curl -fsS 失败则打印响应体并返回非 0，便于定位 Gitee 401/403/404
  local out rc
  out=$(curl -fsS "$@" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "$out" >&2
    return $rc
  fi
  echo "$out"
}

# ---------- 子命令 ----------
cmd_comment_pr() {
  local pr="$1" body_src="$2" body
  [[ -z "$pr" ]] && die "comment-pr 需要参数: <pr_number>"

  # body 是文件路径就读文件；否则直接当作文本
  if [[ -f "$body_src" ]]; then
    body="$(cat "$body_src")"
  else
    body="${body_src:-}"
  fi
  [[ -z "$body" ]] && die "评论内容为空"

  ensure_token
  derive_owner_repo

  log "评论 PR #$pr -> $GITEE_OWNER/$GITEE_REPO"

  # Gitee API: POST /repos/{owner}/{repo}/pulls/{number}/comments
  # 使用 multipart/form-data，避免复杂 JSON 转义
  local out
  out=$(curl_cmd -X POST \
    -F "access_token=${GITEE_TOKEN}" \
    -F "body=${body}" \
    "${GITEE_ENDPOINT}/repos/${GITEE_OWNER}/${GITEE_REPO}/pulls/${pr}/comments" 2>&1) \
    || { log "评论失败: $out"; return 1; }

  log "评论成功"
  return 0
}

cmd_commit_state() {
  local sha="$1" state="$2" desc="${3:-}"
  [[ -z "$sha" ]] && die "commit-state 需要参数: <commit_sha>"
  case "$state" in
    pending|success|failure) ;;
    *) die "state 只能是 pending | success | failure" ;;
  esac

  ensure_token
  derive_owner_repo

  log "更新 commit 状态 $sha -> $state ($GITEE_OWNER/$GITEE_REPO)"

  local out
  out=$(curl_cmd -X POST \
    -F "access_token=${GITEE_TOKEN}" \
    -F "state=${state}" \
    -F "context=code-safety-checker" \
    -F "description=${desc:-code-safety-checker gate}" \
    "${GITEE_ENDPOINT}/repos/${GITEE_OWNER}/${GITEE_REPO}/statuses/${sha}" 2>&1) \
    || { log "状态更新失败: $out"; return 1; }

  log "状态更新成功"
  return 0
}

# ---------- 主入口 ----------
sub="${1:-}"
case "$sub" in
  comment-pr)   shift; cmd_comment_pr "$@" ;;
  commit-state) shift; cmd_commit_state "$@" ;;
  -h|--help|help)
    sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "用法: $0 <comment-pr|commit-state> ..."; exit 2
    ;;
esac
