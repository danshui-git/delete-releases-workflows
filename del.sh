#!/usr/bin/env bash

# ------------------------------
# 全局变量定义
# ------------------------------
set -euo pipefail
IFS=$'\n\t'

# 默认参数
delete_releases="false"
delete_tags="false"
prerelease_option="all"
releases_keep_latest=90
releases_keep_keyword=()
delete_workflows="false"
workflows_keep_latest=0
workflows_keep_day=90
workflows_keep_keyword=()
out_log="false"
repo=""
gh_token=""
max_releases_fetch=100
max_workflows_fetch=100

# 常量
GITHUB_API="https://api.github.com"
PER_PAGE=100
MAX_PAGE=100
TIMEOUT=30

# 颜色定义
COLOR_RESET="\033[0m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_PURPLE="\033[35m"
COLOR_CYAN="\033[36m"

# 日志函数
log() {
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  case "$1" in
    "INFO")    echo -e "${COLOR_BLUE}[${timestamp}] [INFO]    $2${COLOR_RESET}" ;;
    "NOTE")    echo -e "${COLOR_YELLOW}[${timestamp}] [NOTE]    $2${COLOR_RESET}" ;;
    "SUCCESS") echo -e "${COLOR_GREEN}[${timestamp}] [SUCCESS] $2${COLOR_RESET}" ;;
    "ERROR")   echo -e "${COLOR_RED}[${timestamp}] [ERROR]   $2${COLOR_RESET}" >&2; exit 1 ;;
  esac
}

# 临时文件清理
cleanup() {
  local files=("${all_releases_list}" "${all_workflows_list}" "${keep_releases_keyword_list}" "${keep_releases_list}" "${keep_keyword_workflows_list}" "${all_workflows_date_list}" "${keep_workflows_list}" "${tmp_josn_file}")
  for file in "${files[@]}"; do
    [[ -f "$file" ]] && rm -f "$file"
  done
}
trap cleanup EXIT

# ------------------------------
# 参数校验函数
# ------------------------------
validate_boolean() {
  if [[ ! "$1" =~ ^(true|false)$ ]]; then
    log "ERROR" "Invalid boolean value: $1 (expected true/false)"
  fi
}

validate_integer() {
  if [[ ! "$1" =~ ^[0-9]+$ || "$1" -lt 0 ]]; then
    log "ERROR" "Invalid integer value: $1 (expected non-negative integer)"
  fi
}

# ------------------------------
# 初始化参数
# ------------------------------
init_var() {
  log "INFO" "Initializing parameters..."

  # 安装依赖
  if ! command -v jq &> /dev/null; then
    log "INFO" "Installing jq..."
    sudo apt-get -qq update && sudo apt-get -qq install jq || log "ERROR" "Failed to install jq"
  fi

  # 解析命令行参数
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--repo)            repo="$2"; shift 2 ;;
      -a|--delete_releases) delete_releases="$2"; validate_boolean "$2"; shift 2 ;;
      -t|--delete_tags)     delete_tags="$2"; validate_boolean "$2"; shift 2 ;;
      -p|--prerelease_option) prerelease_option="$2"; shift 2 ;;
      -l|--releases_keep_latest) releases_keep_latest="$2"; validate_integer "$2"; shift 2 ;;
      -w|--releases_keep_keyword) IFS='/' read -r -a releases_keep_keyword <<< "$2"; shift 2 ;;
      -s|--delete_workflows) delete_workflows="$2"; validate_boolean "$2"; shift 2 ;;
      -L|--workflows_keep_latest) workflows_keep_latest="$2"; validate_integer "$2"; shift 2 ;;
      -d|--workflows_keep_day) workflows_keep_day="$2"; validate_integer "$2"; shift 2 ;;
      -k|--workflows_keep_keyword) IFS='/' read -r -a workflows_keep_keyword <<< "$2"; shift 2 ;;
      -o|--out_log)         out_log="$2"; validate_boolean "$2"; shift 2 ;;
      -g|--gh_token)        gh_token="$2"; shift 2 ;;
      -R|--max_releases_fetch) max_releases_fetch="$2"; validate_integer "$2"; shift 2 ;;
      -W|--max_workflows_fetch) max_workflows_fetch="$2"; validate_integer "$2"; shift 2 ;;
      *) log "ERROR" "Unknown option: $1" ;;
    esac
  done

  # 验证必要参数
  [[ -z "$gh_token" ]] && log "ERROR" "GitHub token (gh_token) is required"
  [[ -z "$repo" ]] && repo="${GITHUB_REPOSITORY:-}"
  [[ -z "$repo" ]] && log "ERROR" "Repository name (repo) is required"

  # 日志输出参数
  log "INFO" "Configuration:"
  log "INFO" "  repo: $repo"
  log "INFO" "  delete_releases: $delete_releases"
  log "INFO" "  delete_tags: $delete_tags"
  log "INFO" "  prerelease_option: $prerelease_option"
  log "INFO" "  releases_keep_latest: $releases_keep_latest"
  log "INFO" "  releases_keep_keyword: ${releases_keep_keyword[*]}"
  log "INFO" "  delete_workflows: $delete_workflows"
  log "INFO" "  workflows_keep_latest: $workflows_keep_latest"
  log "INFO" "  workflows_keep_day: $workflows_keep_day"
  log "INFO" "  workflows_keep_keyword: ${workflows_keep_keyword[*]}"
  log "INFO" "  max_releases_fetch: $max_releases_fetch"
  log "INFO" "  max_workflows_fetch: $max_workflows_fetch"
  log "INFO" "  out_log: $out_log"
}

# ------------------------------
# GitHub API 请求函数
# ------------------------------
api_request() {
  local method="$1"
  local endpoint="$2"
  local params="${3:-}"
  local output_file="${4:-}"
  
  local url="${GITHUB_API}/${endpoint}"
  [[ -n "$params" ]] && url="${url}?${params}"
  
  log "INFO" "API Request: ${method} ${url}"
  
  local response
  response=$(curl -sSL -w "\n%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${gh_token}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -X "$method" \
    "$url")
  
  local status_code=$(echo "$response" | tail -n1)
  local body=$(echo "$response" | head -n -1)
  
  if [[ "$status_code" -lt 200 || "$status_code" -ge 300 ]]; then
    log "ERROR" "API request failed (${status_code}): ${body}"
  fi
  
  [[ -n "$output_file" ]] && echo "$body" > "$output_file"
  echo "$body"
}

# ------------------------------
# Releases 处理函数
# ------------------------------
get_releases_list() {
  log "INFO" "Fetching releases list (max: $max_releases_fetch)..."
  
  all_releases_list=$(mktemp)
  page=1
  total_fetched=0
  
  while [[ $page -le $MAX_PAGE && $total_fetched -lt $max_releases_fetch ]]; do
    # 计算本次请求最多获取的数量
    remaining=$((max_releases_fetch - total_fetched))
    per_page=$((remaining < PER_PAGE ? remaining : PER_PAGE))
    
    response=$(api_request "GET" "repos/${repo}/releases" "per_page=${per_page}&page=${page}")
    count=$(echo "$response" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
      break
    fi
    
    log "INFO" "Fetched ${count} releases from page ${page}"
    
    # 提取需要的字段并追加到结果文件
    echo "$response" | jq -c '.[] | {date: .published_at, id: .id, prerelease: .prerelease, tag_name: .tag_name}' >> "$all_releases_list"
    
    total_fetched=$((total_fetched + count))
    
    if [[ "$count" -lt "$per_page" ]]; then
      break
    fi
    
    page=$((page + 1))
  done
  
  if [[ -s "$all_releases_list" ]]; then
    log "INFO" "Total releases fetched: $(wc -l < "$all_releases_list")"
    [[ "$out_log" == "true" ]] && log "INFO" "Releases list:\n$(cat "$all_releases_list")"
  else
    log "NOTE" "No releases found"
  fi
}

out_releases_list() {
  log "INFO" "Processing releases list..."
  
  if [[ ! -s "$all_releases_list" ]]; then
    log "NOTE" "Releases list is empty, skipping"
    return
  fi
  
  # 基于prerelease选项过滤
  case "$prerelease_option" in
    "all")
      log "INFO" "Keeping all releases (prerelease option: all)"
      ;;
    "only")
      log "INFO" "Filtering for prereleases only"
      jq -c 'select(.prerelease == true)' "$all_releases_list" > "${all_releases_list}.filtered"
      mv "${all_releases_list}.filtered" "$all_releases_list"
      ;;
    "exclude")
      log "INFO" "Excluding prereleases"
      jq -c 'select(.prerelease == false)' "$all_releases_list" > "${all_releases_list}.filtered"
      mv "${all_releases_list}.filtered" "$all_releases_list"
      ;;
    *)
      log "ERROR" "Invalid prerelease option: $prerelease_option"
      ;;
  esac
  
  # 基于关键词过滤
  keep_releases_keyword_list=$(mktemp)
  if [[ ${#releases_keep_keyword[@]} -gt 0 ]]; then
    log "INFO" "Filtering releases by keywords: ${releases_keep_keyword[*]}"
    
    for keyword in "${releases_keep_keyword[@]}"; do
      jq -c --arg kw "$keyword" 'select(.tag_name | contains($kw))' "$all_releases_list" >> "$keep_releases_keyword_list"
    done
    
    if [[ -s "$keep_releases_keyword_list" ]]; then
      log "INFO" "Found $(wc -l < "$keep_releases_keyword_list") releases to keep by keyword"
      
      # 从待删除列表中移除需要保留的
      comm -23 <(sort "$all_releases_list") <(sort "$keep_releases_keyword_list") > "${all_releases_list}.filtered"
      mv "${all_releases_list}.filtered" "$all_releases_list"
    fi
  fi
  
  # 按日期排序并保留最新的N个
  keep_releases_list=$(mktemp)
  if [[ -s "$all_releases_list" && "$releases_keep_latest" -gt 0 ]]; then
    log "INFO" "Sorting releases by date and keeping latest $releases_keep_latest"
    
    # 按日期排序（最新的在前）
    jq -s 'sort_by(.date) | reverse' "$all_releases_list" > "${all_releases_list}.sorted"
    
    # 保留最新的N个
    head -n "$releases_keep_latest" "${all_releases_list}.sorted" > "$keep_releases_list"
    
    # 剩下的是要删除的
    tail -n +$((releases_keep_latest + 1)) "${all_releases_list}.sorted" > "$all_releases_list"
    
    log "INFO" "Will keep $releases_keep_latest releases, delete $(wc -l < "$all_releases_list")"
    [[ "$out_log" == "true" ]] && log "INFO" "Releases to delete:\n$(cat "$all_releases_list")"
  fi
}

del_releases_file() {
  log "INFO" "Deleting releases..."
  
  if [[ ! -s "$all_releases_list" ]]; then
    log "NOTE" "No releases to delete, skipping"
    return
  fi
  
  local count=0
  while IFS= read -r line; do
    release_id=$(echo "$line" | jq -r '.id')
    tag_name=$(echo "$line" | jq -r '.tag_name')
    
    log "INFO" "Deleting release: $tag_name (ID: $release_id)"
    
    api_request "DELETE" "repos/${repo}/releases/${release_id}"
    
    count=$((count + 1))
    sleep 0.5  # 避免触发API速率限制
  done < "$all_releases_list"
  
  log "SUCCESS" "Deleted $count releases"
}

del_releases_tags() {
  log "INFO" "Deleting tags..."
  
  if [[ "$delete_tags" != "true" || ! -s "$all_releases_list" ]]; then
    log "NOTE" "No tags to delete, skipping"
    return
  fi
  
  local count=0
  while IFS= read -r line; do
    tag_name=$(echo "$line" | jq -r '.tag_name')
    
    log "INFO" "Deleting tag: $tag_name"
    
    api_request "DELETE" "repos/${repo}/git/refs/tags/${tag_name}"
    
    count=$((count + 1))
    sleep 0.5  # 避免触发API速率限制
  done < "$all_releases_list"
  
  log "SUCCESS" "Deleted $count tags"
}

# ------------------------------
# Workflows 处理函数
# ------------------------------
get_workflows_list() {
  log "INFO" "Fetching workflow runs list (max: $max_workflows_fetch)..."
  
  all_workflows_list=$(mktemp)
  page=1
  total_fetched=0
  
  while [[ $page -le $MAX_PAGE && $total_fetched -lt $max_workflows_fetch ]]; do
    # 计算本次请求最多获取的数量
    remaining=$((max_workflows_fetch - total_fetched))
    per_page=$((remaining < PER_PAGE ? remaining : PER_PAGE))
    
    response=$(api_request "GET" "repos/${repo}/actions/runs" "per_page=${per_page}&page=${page}")
    count=$(echo "$response" | jq '.workflow_runs | length')
    
    if [[ "$count" -eq 0 ]]; then
      break
    fi
    
    log "INFO" "Fetched ${count} workflow runs from page ${page}"
    
    # 提取需要的字段并追加到结果文件
    echo "$response" | jq -c '.workflow_runs[] | select(.status != "in_progress") | {date: .updated_at, id: .id, name: .name}' >> "$all_workflows_list"
    
    total_fetched=$((total_fetched + count))
    
    if [[ "$count" -lt "$per_page" ]]; then
      break
    fi
    
    page=$((page + 1))
  done
  
  if [[ -s "$all_workflows_list" ]]; then
    log "INFO" "Total workflow runs fetched: $(wc -l < "$all_workflows_list")"
    [[ "$out_log" == "true" ]] && log "INFO" "Workflow runs list:\n$(cat "$all_workflows_list")"
  else
    log "NOTE" "No workflow runs found"
  fi
}

out_workflows_list() {
  log "INFO" "Processing workflow runs list..."
  
  if [[ ! -s "$all_workflows_list" ]]; then
    log "NOTE" "Workflow runs list is empty, skipping"
    return
  fi
  
  # 基于关键词过滤
  keep_keyword_workflows_list=$(mktemp)
  if [[ ${#workflows_keep_keyword[@]} -gt 0 ]]; then
    log "INFO" "Filtering workflow runs by keywords: ${workflows_keep_keyword[*]}"
    
    for keyword in "${workflows_keep_keyword[@]}"; do
      jq -c --arg kw "$keyword" 'select(.name | contains($kw))' "$all_workflows_list" >> "$keep_keyword_workflows_list"
    done
    
    if [[ -s "$keep_keyword_workflows_list" ]]; then
      log "INFO" "Found $(wc -l < "$keep_keyword_workflows_list") workflow runs to keep by keyword"
      
      # 从待删除列表中移除需要保留的
      comm -23 <(sort "$all_workflows_list") <(sort "$keep_keyword_workflows_list") > "${all_workflows_list}.filtered"
      mv "${all_workflows_list}.filtered" "$all_workflows_list"
    fi
  fi
  
  # 基于保留数量或天数过滤
  keep_workflows_list=$(mktemp)
  if [[ -s "$all_workflows_list" ]]; then
    if [[ "$workflows_keep_latest" -gt 0 ]]; then
      # 保留最新的N个
      log "INFO" "Sorting workflow runs by date and keeping latest $workflows_keep_latest"
      
      # 按日期排序（最新的在前）
      jq -s 'sort_by(.date) | reverse' "$all_workflows_list" > "${all_workflows_list}.sorted"
      
      # 保留最新的N个
      head -n "$workflows_keep_latest" "${all_workflows_list}.sorted" > "$keep_workflows_list"
      
      # 剩下的是要删除的
      tail -n +$((workflows_keep_latest + 1)) "${all_workflows_list}.sorted" > "$all_workflows_list"
      
      log "INFO" "Will keep $workflows_keep_latest workflow runs, delete $(wc -l < "$all_workflows_list")"
    elif [[ "$workflows_keep_day" -gt 0 ]]; then
      # 保留指定天数内的
      log "INFO" "Keeping workflow runs newer than $workflows_keep_day days"
      
      cutoff_date=$(date -d "$workflows_keep_day days ago" +%Y-%m-%dT%H:%M:%SZ)
      
      while IFS= read -r line; do
        run_date=$(echo "$line" | jq -r '.date')
        
        if [[ "$run_date" > "$cutoff_date" ]]; then
          echo "$line" >> "$keep_workflows_list"
        else
          echo "$line" >> "$all_workflows_list.filtered"
        fi
      done < "$all_workflows_list"
      
      mv "$all_workflows_list.filtered" "$all_workflows_list"
      
      log "INFO" "Will keep $(wc -l < "$keep_workflows_list") workflow runs, delete $(wc -l < "$all_workflows_list")"
    else
      log "INFO" "No retention criteria specified, will delete all $(wc -l < "$all_workflows_list") workflow runs"
    fi
    
    [[ "$out_log" == "true" ]] && log "INFO" "Workflow runs to delete:\n$(cat "$all_workflows_list")"
  fi
}

del_workflows_runs() {
  log "INFO" "Deleting workflow runs..."
  
  if [[ ! -s "$all_workflows_list" ]]; then
    log "NOTE" "No workflow runs to delete, skipping"
    return
  fi
  
  local count=0
  while IFS= read -r line; do
    run_id=$(echo "$line" | jq -r '.id')
    run_name=$(echo "$line" | jq -r '.name')
    
    log "INFO" "Deleting workflow run: $run_name (ID: $run_id)"
    
    api_request "DELETE" "repos/${repo}/actions/runs/${run_id}"
    
    count=$((count + 1))
    sleep 0.5  # 避免触发API速率限制
  done < "$all_workflows_list"
  
  log "SUCCESS" "Deleted $count workflow runs"
}

# ------------------------------
# 主函数
# ------------------------------
main() {
  log "INFO" "Starting delete older releases and workflows tool..."
  
  # 初始化参数
  init_var "$@"
  
  # 处理releases
  if [[ "$delete_releases" == "true" ]]; then
    log "INFO" "Processing releases deletion..."
    get_releases_list
    out_releases_list
    del_releases_file
    del_releases_tags
  else
    log "INFO" "Skipping releases deletion"
  fi
  
  # 处理workflows
  if [[ "$delete_workflows" == "true" ]]; then
    log "INFO" "Processing workflows deletion..."
    get_workflows_list
    out_workflows_list
    del_workflows_runs
  else
    log "INFO" "Skipping workflows deletion"
  fi
  
  log "SUCCESS" "All operations completed successfully!"
}

# 执行主函数
main "$@"
