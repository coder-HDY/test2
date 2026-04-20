#!/usr/bin/env bash
# ============================================================
# 【仓库1 专用】生成脚本
# 从 source/report.yml（含 workflow_call）生成目标仓库可直接使用的独立版本。
# 独立版本会：
#   1. 移除 workflow_call 触发器
#   2. 把 inputs.repo_name 替换为 github.repository
#   3. 保持其余逻辑完全一致
# ============================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FILE="${ROOT_DIR}/source/report.yml"
OUTPUT_FILE="/tmp/report-generated.yml"


if [[ ! -f "${SOURCE_FILE}" ]]; then
  echo "Source workflow not found: ${SOURCE_FILE}" >&2
  exit 1
fi



# ---------- 用 Python 结构化解析，移除 workflow_call 触发器 ----------
python3 <<PY
import re, sys

src_path = "${SOURCE_FILE}"
out_path = "${OUTPUT_FILE}"

src = open(src_path).read()

# 1. 移除 __WORKFLOW_CALL_START__ ... __WORKFLOW_CALL_END__ 哨兵块（含首尾哨兵行）
src = re.sub(
  r'[ \t]*# __WORKFLOW_CALL_START__[ \t]*\n.*?[ \t]*# __WORKFLOW_CALL_END__[ \t]*\n',
  '',
  src,
  flags=re.DOTALL
)

# 2. 补回 on: 行（哨兵块之前的 on: 已正确存在，步骤1只删了哨兵内的内容）
#    如果 on: 行在删除后变成 "on:" 后面直接跟缩进内容，不需要处理。
#    但如果 on: 行本身没有被误删就直接保留。

# 3. 替换 inputs.repo_name -> github.repository
src = src.replace("inputs.repo_name || github.repository", "github.repository")
src = src.replace("\${{ inputs.repo_name }}", "\${{ github.repository }}")

# 4. 清理源模板注释标记
src = re.sub(r'# ={5,}[^\n]*\n# 【仓库1[^\n]*\n# ={5,}[^\n]*\n', '', src)

# 5. 清理名称中的（源模板）后缀
src = src.replace("name: 自动化报告（源模板）", "name: 自动化报告")

# 6. 去掉多余的连续空行（超过 1 行的空行压缩成 1 行）
src = re.sub(r'\n{3,}', '\n\n', src)

open(out_path, 'w').write(src)
print(f"Generated {out_path}")
PY
