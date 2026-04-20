#!/usr/bin/env bash
# ============================================================
# 【仓库1 专用】分发脚本
# 对每个目标仓库：
#   1. clone 目标仓库
#   2. 创建机器人分支
#   3. 覆盖 .github/workflows/report.yml
#   4. 有变更则推送并创建 PR 到 main
#   5. 无变更自动跳过
#
# 环境变量：
#   GH_TOKEN       必须，Personal Access Token 或 GitHub App token
#                  需要对目标仓库有 contents:write + pull_requests:write
#   ORG            组织名，默认 coder-HDY
#   BASE_BRANCH    PR 目标分支，默认 main
#   BRANCH_PREFIX  机器人分支前缀，默认 bot/report-sync
#   REPO_FILTER    可选，逗号分隔的仓库名，只处理指定的仓库
#                  例：REPO_FILTER=test3,test4
# ============================================================
set -euo pipefail

CONTROL_REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CICD_DIR="${CONTROL_REPO_DIR}/cicd"
GENERATE_SCRIPT="${CICD_DIR}/scripts/generate-report.sh"
SOURCE_WORKFLOW="/tmp/report-generated.yml"

ORG="${ORG:-coder-HDY}"
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH_PREFIX="${BRANCH_PREFIX:-bot/report-sync}"
REPO_FILTER="${REPO_FILTER:-}"
SYNC_BRANCH="${BRANCH_PREFIX}-$(date +%Y%m%d-%H%M%S)"
COMMIT_MESSAGE="chore(ci): sync report workflow from central template"
PR_TITLE="chore(ci): sync report workflow from central template"
SOURCE_COMMIT="$(git -C "${CONTROL_REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

# ===== 前置检查 =====
if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required but not found." >&2
  exit 1
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is required." >&2
  exit 1
fi
gh auth status >/dev/null

# ===== 生成独立版工作流 =====
bash "${GENERATE_SCRIPT}"

if [[ ! -f "${SOURCE_WORKFLOW}" ]]; then
  echo "Generated workflow missing: ${SOURCE_WORKFLOW}" >&2
  exit 1
fi

# ===== 目标仓库列表 =====
# 默认从 repos.txt 读取（每行一个仓库名，不含 org 前缀）
# 也可以直接在此处硬编码：
#   repos=(test2 test3 test4)
REPOS_FILE="${CICD_DIR}/repos.txt"
repos=()
if [[ -f "${REPOS_FILE}" ]]; then
  while IFS= read -r repo; do
    [[ -z "${repo}" || "${repo}" == \#* ]] && continue
    repos+=("${repo}")
  done < "${REPOS_FILE}"
fi

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "No target repos configured. Add repo names to repos.txt (one per line)." >&2
  exit 1
fi

# 可选：仅处理指定仓库
if [[ -n "${REPO_FILTER}" ]]; then
  IFS=',' read -r -a selected <<< "${REPO_FILTER}"
  filtered=()
  for repo in "${repos[@]}"; do
    for pick in "${selected[@]}"; do
      [[ "${repo}" == "${pick}" ]] && filtered+=("${repo}")
    done
  done
  repos=("${filtered[@]}")
fi

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "No repositories match REPO_FILTER=${REPO_FILTER}" >&2
  exit 1
fi

# ===== 分发 =====
tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

summary_file="${tmp_root}/summary.txt"
: > "${summary_file}"

echo "Sync branch : ${SYNC_BRANCH}"
echo "Total repos : ${#repos[@]}"
echo ""

for repo in "${repos[@]}"; do
  full_repo="${ORG}/${repo}"
  workdir="${tmp_root}/${repo}"

  echo "===== ${full_repo} ====="

  gh repo clone "${full_repo}" "${workdir}" -- --quiet

  pushd "${workdir}" >/dev/null
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${full_repo}.git"
  git checkout -b "${SYNC_BRANCH}"
  mkdir -p .github/workflows
  cp "${SOURCE_WORKFLOW}" .github/workflows/report.yml
  git add .github/workflows/report.yml

  if git diff --cached --quiet -- .github/workflows/report.yml; then
    echo "No changes detected, skipping PR."
    echo "${full_repo}: SKIPPED(no changes)" >> "${summary_file}"
    popd >/dev/null
    continue
  fi
  git -c user.name="report-sync-bot" \
      -c user.email="report-sync-bot@users.noreply.github.com" \
      commit -m "${COMMIT_MESSAGE}"
  git push -u origin "${SYNC_BRANCH}"

  pr_body=$(cat <<EOF
Automated report workflow sync from central template.

- Source repo  : ${GITHUB_REPOSITORY:-local}
- Source commit: ${SOURCE_COMMIT}
- Generated from: cicd/source/report.yml
- Target file   : .github/workflows/report.yml

This PR is created by the report workflow distribution automation.
**Review and merge to apply the updated workflow.**
EOF
)

  gh pr create \
    --repo "${full_repo}" \
    --base "${BASE_BRANCH}" \
    --head "${SYNC_BRANCH}" \
    --title "${PR_TITLE}" \
    --body "${pr_body}" > /tmp/pr-url.txt

  pr_url="$(cat /tmp/pr-url.txt)"
  echo "PR created: ${pr_url}"
  echo "${full_repo}: ${pr_url}" >> "${summary_file}"

  popd >/dev/null
  echo ""
done

echo "==== Distribution Summary ===="
cat "${summary_file}"
