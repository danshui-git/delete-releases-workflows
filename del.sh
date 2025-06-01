#!/usr/bin/env bash

# 确保使用系统jq
export PATH="/usr/bin:$PATH"

# 验证jq是否可用
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq command not found" >&2
    exit 1
fi

# 设置默认值
github_per_page="100"  # 每次请求获取的数量
github_max_page="10"   # 最大请求页数限制
api_delay=1           # API请求之间的延迟(秒)
max_retries=3         # 最大重试次数

# 设置字体颜色
STEPS="[\033[95m 执行 \033[0m]"
INFO="[\033[94m 信息 \033[0m]"
NOTE="[\033[93m 注意 \033[0m]"
ERROR="[\033[31m 错误 \033[0m]"
DISPLAY="[\033[91m 日志 \033[0m]"
SUCCESS="[\033[92m 成功 \033[0m]"

# 临时文件目录
TMP_DIR=$(mktemp -d)
chmod 755 "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

#==============================================================================================

# 转义jq字符串中的特殊字符
escape_jq_string() {
    local str="$1"
    # 转义反斜杠和双引号
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    echo "$str"
}

cleanup() {
    rm -rf "${TMP_DIR}"
}

error_msg() {
    echo -e "${ERROR} ${1}"
    cleanup
    exit 1
}

# 安全的API请求函数
github_api_request() {
    local url="$1"
    local method="${2:-GET}"
    local retry_count=0
    local response
    local http_code
    
    while [[ "$retry_count" -lt "$max_retries" ]]; do
        # 添加请求延迟
        if [[ "$retry_count" -gt 0 ]]; then
            sleep "$api_delay"
        fi
        
        response=$(curl -s -w "\n%{http_code}" -L -f \
            -X "$method" \
            -H "Authorization: Bearer ${gh_token}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$url")
        
        http_code=$(echo "$response" | tail -n1)
        response=$(echo "$response" | sed '$d')
        
        # 检查速率限制
        if [[ "$http_code" -eq 403 ]]; then
            local reset_time=$(curl -s -I \
                -H "Authorization: Bearer ${gh_token}" \
                "https://api.github.com" | grep -i "x-ratelimit-reset" | tr -d '\r' | awk '{print $2}')
            
            if [[ -n "$reset_time" ]]; then
                local current_time=$(date +%s)
                local wait_time=$((reset_time - current_time + 1))
                
                if [[ "$wait_time" -gt 0 ]]; then
                    echo -e "${NOTE} 达到API速率限制，等待 ${wait_time}秒后重试..."
                    sleep "$wait_time"
                    continue
                fi
            fi
        fi
        
        # 成功响应
        if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
            echo "$response"
            return 0
        fi
        
        # 其他错误
        retry_count=$((retry_count + 1))
        echo -e "${ERROR} API请求失败 (尝试 $retry_count/$max_retries): HTTP $http_code"
        sleep "$api_delay"
    done
    
    echo -e "${ERROR} 达到最大重试次数，API请求失败: $url"
    return 1
}

init_var() {
    echo -e "${STEPS} 开始初始化变量..."

    # 获取参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--repo) repo="$2"; shift 2 ;;
            -a|--delete_releases) delete_releases="$2"; shift 2 ;;
            -t|--delete_tags) delete_tags="$2"; shift 2 ;;
            -p|--prerelease_option) prerelease_option="$2"; shift 2 ;;
            -l|--releases_keep_latest) releases_keep_latest="$2"; shift 2 ;;
            -w|--releases_keep_keyword) IFS="/" read -r -a releases_keep_keyword <<< "$2"; shift 2 ;;
            -c|--max_releases_fetch) max_releases_fetch="$2"; shift 2 ;;
            -s|--delete_workflows) delete_workflows="$2"; shift 2 ;;
            -d|--workflows_keep_latest) workflows_keep_latest="$2"; shift 2 ;;
            -k|--workflows_keep_keyword) IFS="/" read -r -a workflows_keep_keyword <<< "$2"; shift 2 ;;
            -h|--max_workflows_fetch) max_workflows_fetch="$2"; shift 2 ;;
            -g|--gh_token) gh_token="$2"; shift 2 ;;
            -o|--out_log) out_log="$2"; shift 2 ;;
            *) error_msg "无效选项 [ $1 ]!"; shift ;;
        esac
    done
    
    echo -e ""
    echo -e "${INFO} repo: [ ${repo} ]"
    echo -e "${INFO} delete_releases: [ ${delete_releases} ]"
    echo -e "${INFO} delete_tags: [ ${delete_tags} ]"
    echo -e "${INFO} prerelease_option: [ ${prerelease_option} ]"
    echo -e "${INFO} releases_keep_latest: [ ${releases_keep_latest} ]"
    echo -e "${INFO} releases_keep_keyword: [ $(echo ${releases_keep_keyword[@]} | xargs) ]"
    echo -e "${INFO} max_releases_fetch: [ ${max_releases_fetch} ]"
    echo -e "${INFO} delete_workflows: [ ${delete_workflows} ]"
    echo -e "${INFO} workflows_keep_latest: [ ${workflows_keep_latest} ]"
    echo -e "${INFO} workflows_keep_keyword: [ $(echo ${workflows_keep_keyword[@]} | xargs) ]"
    echo -e "${INFO} max_workflows_fetch: [ ${max_workflows_fetch} ]"
    echo -e "${INFO} out_log: [ ${out_log} ]"
    echo -e ""
}

get_total_pages() {
    local endpoint="$1"
    local per_page="$2"
    
    # 获取第一页数据来确定总页数
    response=$(curl -s -I \
        -H "Authorization: Bearer ${gh_token}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${repo}/${endpoint}?per_page=${per_page}&page=1")
    
    # 从响应头中获取总页数
    link_header=$(echo "$response" | grep -i '^link:' | tr -d '\r')
    if [[ -n "$link_header" ]]; then
        last_page=$(echo "$link_header" | grep -o 'page=[0-9]*>; rel="last"' | cut -d'=' -f2 | cut -d'>' -f1)
        echo "$last_page"
    else
        echo "1"  # 只有一页
    fi
}

get_releases_list() {
    echo -e "${STEPS} 开始查询发布列表..."

    # 创建临时文件存储结果
    all_releases_list="${TMP_DIR}/A_all_releases_list.json"
    > "${all_releases_list}"
    
    # 获取总页数
    total_pages=$(get_total_pages "releases" "$github_per_page")
    total_pages=$((total_pages < github_max_page ? total_pages : github_max_page))
    echo -e "${INFO} 总页数: ${total_pages}"

    # 从最后一页开始获取发布列表
    for (( page=total_pages; page>=1; page-- )); do
        echo -e "${INFO} 正在获取第 ${page}/${total_pages} 页..."
        
        response=$(github_api_request "https://api.github.com/repos/${repo}/releases?per_page=${github_per_page}&page=${page}") || {
            echo -e "${ERROR} 从GitHub API获取发布失败 (第 $page 页)"
            continue
        }

        # 获取当前页返回的结果数量
        get_results_length="$(echo "${response}" | jq '. | length')"
        echo -e "${INFO} (1.1.${page}) 查询第 [ ${page} ] 页，返回 [ ${get_results_length} ] 条结果"

        # 处理结果并追加到文件
        if [[ "$get_results_length" -gt 0 ]]; then
            echo "${response}" | jq -c '.[] | {date: .published_at, id: .id, prerelease: .prerelease, tag_name: .tag_name}' >> "${all_releases_list}"
        fi
        
        # 添加请求间隔
        if [[ "$page" -gt 1 ]]; then
            sleep "$api_delay"
        fi
    done

    # 按日期排序（从旧到新）
    if [[ -s "${all_releases_list}" ]]; then
        jq -s 'sort_by(.date)' "${all_releases_list}" | jq -c '.[]' > "${all_releases_list}.tmp"
        mv "${all_releases_list}.tmp" "${all_releases_list}"
        
        # 应用max_releases_fetch限制
        if [[ "$(wc -l < "${all_releases_list}")" -gt "${max_releases_fetch}" ]]; then
            echo -e "${INFO} (1.3.1) 发布数量超过max_releases_fetch限制 [${max_releases_fetch}]，将保留最旧的${max_releases_fetch}条"
            head -n "${max_releases_fetch}" "${all_releases_list}" > "${all_releases_list}.tmp"
            mv "${all_releases_list}.tmp" "${all_releases_list}"
        fi
        
        # 打印结果日志
        actual_count=$(wc -l < "${all_releases_list}")
        echo -e "${INFO} (1.3.2) 获取发布信息请求成功"
        echo -e "${INFO} (1.3.3) 获取到的发布总数: [ ${actual_count} ]"
        if [[ "${out_log}" == "true" ]]; then
            if [[ -s "${all_releases_list}" ]]; then
                echo -e "${DISPLAY} (1.3.4) 所有发布列表:"
                cat "${all_releases_list}" | jq -c .
                echo -e ""
            else
                echo -e "${NOTE} (1.3.5) 发布列表为空"
            fi
        fi
    else
        echo -e "${NOTE} (1.3.6) 发布列表为空，跳过"
    fi
}

filter_releases() {
    echo -e "${STEPS} 开始过滤发布列表..."

    # 输入文件
    all_releases_list="${TMP_DIR}/A_all_releases_list.json"
    # 输出文件
    filtered_releases_list="${TMP_DIR}/B_filtered_releases_list.json"
    > "${filtered_releases_list}"

    # 确保文件是JSON数组格式
    if [[ -s "${all_releases_list}" ]]; then
        # 如果文件不是数组格式，转换为数组
        if ! jq -e '. | type == "array"' "${all_releases_list}" &>/dev/null; then
            jq -s '.' "${all_releases_list}" > "${all_releases_list}.tmp"
            mv "${all_releases_list}.tmp" "${all_releases_list}"
        fi
    fi

    # 0. 首先处理预发布选项过滤
    if [[ -s "${all_releases_list}" ]]; then
        if [[ "${prerelease_option}" == "all" ]]; then
            echo -e "${NOTE} (1.4.1) 不过滤预发布选项，跳过"
            cp "${all_releases_list}" "${filtered_releases_list}"
        elif [[ "${prerelease_option}" == "false" ]]; then
            echo -e "${INFO} (1.4.2) 过滤预发布选项: [ false ]"
            jq -c '[.[] | select(.prerelease == false)]' "${all_releases_list}" > "${filtered_releases_list}"
        elif [[ "${prerelease_option}" == "true" ]]; then
            echo -e "${INFO} (1.4.3) 过滤预发布选项: [ true ]"
            jq -c '[.[] | select(.prerelease == true)]' "${all_releases_list}" > "${filtered_releases_list}"
        fi
        
        # 日志输出
        if [[ "${out_log}" == "true" ]]; then
            echo -e "${DISPLAY} (1.4.4) 当前发布列表:"
            jq -c '.[]' "${filtered_releases_list}"
        fi
    else
        echo -e "${NOTE} (1.4.5) 发布列表为空，跳过预发布过滤"
        > "${filtered_releases_list}"
    fi

    # 1. 处理关键词过滤（仅在有关键词时执行）
    if [[ "${#releases_keep_keyword[@]}" -ge "1" && -s "${filtered_releases_list}" ]]; then
        echo -e "${INFO} (1.5.1) 过滤标签关键词: [ $(echo ${releases_keep_keyword[@]} | xargs) ]"
        
        # 构建关键词过滤条件
        local filter_condition=""
        for keyword in "${releases_keep_keyword[@]}"; do
            # 跳过空关键词
            [[ -z "${keyword}" ]] && continue
            
            # 转义关键词中的特殊字符
            local escaped_keyword=$(escape_jq_string "${keyword}")
            filter_condition+=" and (.tag_name | contains(\"${escaped_keyword}\") | not)"
        done

        # 如果所有关键词都为空，则跳过过滤
        if [[ -n "${filter_condition}" ]]; then
            filter_condition="${filter_condition# and }"  # 移除开头的" and "
            jq -c "[.[] | select(${filter_condition})]" "${filtered_releases_list}" > "${filtered_releases_list}.tmp"
            mv "${filtered_releases_list}.tmp" "${filtered_releases_list}"
        fi
        
        # 记录保留的发布（仅日志）
        if [[ "${out_log}" == "true" ]]; then
            kept_releases_list="${TMP_DIR}/kept_releases.json"
            if [[ -n "${filter_condition}" ]]; then
                jq -c "[.[] | select(${filter_condition} | not)]" "${all_releases_list}" > "${kept_releases_list}"
            else
                cp "${all_releases_list}" "${kept_releases_list}"
            fi
            echo -e "${DISPLAY} (1.5.2) 符合条件标签列表:"
            jq -c '.[]' "${kept_releases_list}"
        fi
    else
        echo -e "${NOTE} (1.5.3) 无关键词过滤，跳过"
    fi

    # 2. 处理保留最新N条
    final_releases_list="${TMP_DIR}/C_final_releases_list.json"
    > "${final_releases_list}"

    if [[ -s "${filtered_releases_list}" ]]; then
        if [[ "${releases_keep_latest}" -eq "0" ]]; then
            echo -e "${INFO} (1.6.1) 将删除所有剩余发布"
            cp "${filtered_releases_list}" "${final_releases_list}"
        else
            echo -e "${INFO} (1.6.2) 保留最新的[ ${releases_keep_latest} ]个发布"
            
            # 获取总数量
            total_count=$(jq 'length' "${filtered_releases_list}")
            
            # 计算要删除的数量
            delete_count=$((total_count > releases_keep_latest ? total_count - releases_keep_latest : 0))
            
            if [[ "${delete_count}" -gt 0 ]]; then
                # 按日期排序（从旧到新）
                jq -c 'sort_by(.date)' "${filtered_releases_list}" > "${filtered_releases_list}.sorted"
                
                # 提取要删除的（最旧的）
                jq -c ".[0:${delete_count}]" "${filtered_releases_list}.sorted" > "${final_releases_list}"
                
                # 记录保留的发布（仅日志）
                if [[ "${out_log}" == "true" ]]; then
                    echo -e "${DISPLAY} (1.6.3) 将被保留的最新发布:"
                    jq -c ".[${delete_count}:]" "${filtered_releases_list}.sorted"
                fi
            else
                echo -e "${NOTE} (1.6.4) 发布数量不足[ ${releases_keep_latest} ]，将全部发布保留"
                > "${final_releases_list}"
            fi
        fi
        
        # 日志输出
        if [[ "${out_log}" == "true" && -s "${final_releases_list}" ]]; then
            echo -e "${DISPLAY} (1.6.5) 将要删除的发布:"
            jq -c '.[]' "${final_releases_list}"
        fi
    else
        echo -e "${NOTE} (1.6.6) 无发布需要处理"
    fi

    # 更新最终列表
    if [[ -s "${final_releases_list}" ]]; then
        mv "${final_releases_list}" "${all_releases_list}"
    else
        > "${all_releases_list}"
    fi
}

delete_releases() {
    echo -e "${STEPS} 开始删除发布..."

    all_releases_list="${TMP_DIR}/A_all_releases_list.json"
    
    if [[ -s "${all_releases_list}" ]]; then
        # 确保文件是JSON数组格式
        if ! jq -e '. | type == "array"' "${all_releases_list}" &>/dev/null; then
            jq -s '.' "${all_releases_list}" > "${all_releases_list}.tmp"
            mv "${all_releases_list}.tmp" "${all_releases_list}"
        fi

        local count=0
        local total=$(jq 'length' "${all_releases_list}")
        
        while read -r release; do
            count=$((count + 1))
            release_id=$(echo "${release}" | jq -r '.id')
            tag_name=$(echo "${release}" | jq -r '.tag_name')
            
            echo -e "${INFO} (1.7.1) 正在删除发布[ ${count}/${total} ]"
            
            # 删除发布
            response=$(github_api_request "https://api.github.com/repos/${repo}/releases/${release_id}" "DELETE") || {
                echo -e "${ERROR} (1.7.2) 删除发布 ${count}、${tag_name} (ID: ${release_id}) 失败"
                continue
            }
                
            echo -e "${SUCCESS} (1.7.3) 删除发布 ${count}、${tag_name} (ID: ${release_id}) 成功"
            
            # 如果启用，删除关联的标签
            if [[ "${delete_tags}" == "true" ]]; then
                echo -e "${INFO} (1.7.4) 正在删除关联标签: ${tag_name}"
                
                tag_response=$(github_api_request "https://api.github.com/repos/${repo}/git/refs/tags/${tag_name}" "DELETE") || {
                    echo -e "${ERROR} (1.7.5) 删除标签 ${tag_name} 失败"
                    continue
                }
                
                echo -e "${SUCCESS} (1.7.6) 标签 ${tag_name} 删除成功"
            fi
            
            # 添加删除间隔
            sleep "$api_delay"
            
        done < <(jq -c '.[]' "${all_releases_list}")
        
        echo -e "${SUCCESS} (1.7.7) 发布删除完成[ ${count}/${total} ]"
    else
        echo -e "${NOTE} (1.7.8) 没有需要删除的发布，跳过"
    fi

    echo -e "${SUCCESS} 删除发布程序运行完毕\n"
}

get_workflows_list() {
    echo -e "${STEPS} 开始查询工作流列表..."

    # 创建临时文件存储结果
    all_workflows_list="${TMP_DIR}/A_all_workflows_list.json"
    > "${all_workflows_list}"
    
    # 计算需要获取的总页数
    local total_items_needed=$((max_workflows_fetch > 0 ? max_workflows_fetch : 1000))
    local total_pages_needed=$(( (total_items_needed + github_per_page - 1) / github_per_page ))
    total_pages_needed=$((total_pages_needed < github_max_page ? total_pages_needed : github_max_page))
    
    echo -e "${INFO} 需要获取的页数: ${total_pages_needed}"

    # 从最后一页开始获取工作流列表
    for (( page=total_pages_needed; page>=1; page-- )); do
        echo -e "${INFO} 正在获取第 ${page}/${total_pages_needed} 页..."
        
        response=$(github_api_request "https://api.github.com/repos/${repo}/actions/runs?per_page=${github_per_page}&page=${page}") || {
            echo -e "${ERROR} 从GitHub API获取工作流失败 (第 $page 页)"
            continue
        }

        # 获取当前页返回的结果数量
        get_results_length="$(echo "${response}" | jq -r '.workflow_runs | length')"
        echo -e "${INFO} (2.1.${page}) 查询第 [ ${page} ] 页，返回 [ ${get_results_length} ] 条结果"

        # 处理结果并追加到文件
        if [[ "$get_results_length" -gt 0 ]]; then
            echo "${response}" | jq -c '.workflow_runs[] | select(.status != "in_progress") | {date: .updated_at, id: .id, name: .name}' >> "${all_workflows_list}"
        fi
        
        # 添加请求间隔
        if [[ "$page" -gt 1 ]]; then
            sleep "$api_delay"
        fi
    done

    # 按日期排序（从旧到新）
    if [[ -s "${all_workflows_list}" ]]; then
        jq -s 'sort_by(.date)' "${all_workflows_list}" | jq -c '.[]' > "${all_workflows_list}.tmp"
        mv "${all_workflows_list}.tmp" "${all_workflows_list}"
        
        # 应用max_workflows_fetch限制
        if [[ "$(wc -l < "${all_workflows_list}")" -gt "${max_workflows_fetch}" ]]; then
            echo -e "${INFO} (2.3.1) 工作流数量超过max_workflows_fetch限制 [${max_workflows_fetch}]，将保留最旧的${max_workflows_fetch}条"
            head -n "${max_workflows_fetch}" "${all_workflows_list}" > "${all_workflows_list}.tmp"
            mv "${all_workflows_list}.tmp" "${all_workflows_list}"
        fi
        
        # 打印结果日志
        actual_count=$(wc -l < "${all_workflows_list}")
        echo -e "${INFO} (2.3.2) 获取工作流信息请求成功"
        echo -e "${INFO} (2.3.3) 获取到的工作流总数: [ ${actual_count} ]"
        if [[ "${out_log}" == "true" ]]; then
            if [[ -s "${all_workflows_list}" ]]; then
                echo -e "${DISPLAY} (2.3.4) 所有工作流运行列表:"
                cat "${all_workflows_list}" | jq -c .
                echo -e ""
            else
                echo -e "${NOTE} (2.3.5) 工作流列表为空"
            fi
        fi
    else
        echo -e "${NOTE} (2.3.6) 工作流列表为空，跳过"
    fi
}

filter_workflows() {
    echo -e "${STEPS} 开始过滤工作流列表..."

    # 输入文件
    all_workflows_list="${TMP_DIR}/A_all_workflows_list.json"
    # 输出文件
    filtered_workflows_list="${TMP_DIR}/B_filtered_workflows_list.json"
    > "${filtered_workflows_list}"

    # 确保文件是JSON数组格式
    if [[ -s "${all_workflows_list}" ]]; then
        # 如果文件不是数组格式，转换为数组
        if ! jq -e '. | type == "array"' "${all_workflows_list}" &>/dev/null; then
            jq -s '.' "${all_workflows_list}" > "${all_workflows_list}.tmp"
            mv "${all_workflows_list}.tmp" "${all_workflows_list}"
        fi
    else
        echo -e "${NOTE} (2.4.0) 工作流列表为空，跳过过滤"
        return
    fi

    # 1. 处理关键词过滤（仅在有关键词时执行）
    if [[ "${#workflows_keep_keyword[@]}" -gt 0 ]]; then
        echo -e "${INFO} (2.4.1) 过滤工作流关键词: [ $(echo ${workflows_keep_keyword[@]} | xargs) ]"
        
        # 构建关键词过滤条件
        local filter_condition=""
        for keyword in "${workflows_keep_keyword[@]}"; do
            # 跳过空关键词
            [[ -z "${keyword}" ]] && continue
            
            # 转义关键词中的特殊字符
            local escaped_keyword=$(escape_jq_string "${keyword}")
            filter_condition+=" and (.name | contains(\"${escaped_keyword}\") | not)"
        done

        # 如果所有关键词都为空，则跳过过滤
        if [[ -n "${filter_condition}" ]]; then
            filter_condition="${filter_condition# and }"  # 移除开头的" and "
            jq -c "[.[] | select(${filter_condition})]" "${all_workflows_list}" > "${filtered_workflows_list}"
        else
            cp "${all_workflows_list}" "${filtered_workflows_list}"
        fi
        
        # 记录保留的工作流（仅日志）
        if [[ "${out_log}" == "true" ]]; then
            kept_workflows_list="${TMP_DIR}/kept_workflows.json"
            if [[ -n "${filter_condition}" ]]; then
                jq -c "[.[] | select(${filter_condition} | not)]" "${all_workflows_list}" > "${kept_workflows_list}"
            else
                cp "${all_workflows_list}" "${kept_workflows_list}"
            fi
            echo -e "${DISPLAY} (2.4.2) 符合条件工作流列表:"
            jq -c '.[]' "${kept_workflows_list}"
        fi
    else
        echo -e "${NOTE} (2.4.3) 无关键词过滤，使用原始列表"
        cp "${all_workflows_list}" "${filtered_workflows_list}"
    fi

    # 2. 处理保留最新N条
    final_workflows_list="${TMP_DIR}/C_final_workflows_list.json"
    > "${final_workflows_list}"

    if [[ -s "${filtered_workflows_list}" ]]; then
        if [[ "${workflows_keep_latest}" -eq "0" ]]; then
            echo -e "${INFO} (2.5.1) 将删除所有剩余工作流"
            cp "${filtered_workflows_list}" "${final_workflows_list}"
        else
            echo -e "${INFO} (2.5.2) 保留最新的[ ${workflows_keep_latest} ]个工作流"
            
            # 获取总数量
            total_count=$(jq 'length' "${filtered_workflows_list}")
            
            # 计算要删除的数量
            delete_count=$((total_count > workflows_keep_latest ? total_count - workflows_keep_latest : 0))
            
            if [[ "${delete_count}" -gt 0 ]]; then
                # 按日期排序（从旧到新）
                jq -c 'sort_by(.date)' "${filtered_workflows_list}" > "${filtered_workflows_list}.sorted"
                
                # 提取要删除的（最旧的）
                jq -c ".[0:${delete_count}]" "${filtered_workflows_list}.sorted" > "${final_workflows_list}"
                
                # 记录保留的工作流（仅日志）
                if [[ "${out_log}" == "true" ]]; then
                    echo -e "${DISPLAY} (2.5.3) 将被保留的最新工作流:"
                    jq -c ".[${delete_count}:]" "${filtered_workflows_list}.sorted"
                fi
            else
                echo -e "${NOTE} (2.5.4) 工作流数量不足[ ${workflows_keep_latest} ]，将全部工作流保留"
                > "${final_workflows_list}"
            fi
        fi
        
        # 日志输出
        if [[ "${out_log}" == "true" && -s "${final_workflows_list}" ]]; then
            echo -e "${DISPLAY} (2.5.5) 将要删除的工作流:"
            jq -c '.[]' "${final_workflows_list}"
        fi
    else
        echo -e "${NOTE} (2.5.6) 无工作流需要处理"
    fi

    # 更新最终列表
    if [[ -s "${final_workflows_list}" ]]; then
        mv "${final_workflows_list}" "${all_workflows_list}"
    else
        > "${all_workflows_list}"
    fi
}

delete_workflows() {
    echo -e "${STEPS} 开始删除工作流..."

    all_workflows_list="${TMP_DIR}/A_all_workflows_list.json"
    
    if [[ -s "${all_workflows_list}" ]]; then
        local count=0
        local total=$(jq 'length' "${all_workflows_list}")
        
        while read -r workflow; do
            count=$((count + 1))
            local workflow_id=$(echo "${workflow}" | jq -r '.id')
            local workflow_name=$(echo "${workflow}" | jq -r '.name')
            
            echo -e "${INFO} (2.6.1) 正在删除工作流[ ${count}/${total} ]"
            
            response=$(github_api_request "https://api.github.com/repos/${repo}/actions/runs/${workflow_id}" "DELETE") || {
                echo -e "${ERROR} (2.6.2) 删除工作流 ${count}、${workflow_name} (ID: ${workflow_id}) 失败"
                continue
            }
                
            echo -e "${SUCCESS} (2.6.3) 删除工作流 ${count}、${workflow_name} (ID: ${workflow_id}) 成功"
            
            # 添加删除间隔
            sleep "$api_delay"
            
        done < <(jq -c '.[]' "${all_workflows_list}")
        
        echo -e "${SUCCESS} (2.6.4) 工作流删除完成[ ${count}/${total} ]"
    else
        echo -e "${NOTE} (2.6.5) 没有需要删除的工作流"
    fi
    
    echo -e "${SUCCESS} 删除工作流程序运行完毕"
}

# 主程序
trap cleanup EXIT

# 显示欢迎信息
echo -e "${STEPS} 欢迎使用删除旧发布和工作流运行工具!"

# 按顺序执行相关操作
init_var "${@}"

# 删除发布
if [[ "${delete_releases}" == "true" ]]; then
    get_releases_list
    filter_releases
    delete_releases
else
    echo -e "${STEPS} 不删除发布和标签"
fi

# 删除工作流
if [[ "${delete_workflows}" == "true" ]]; then
    get_workflows_list
    filter_workflows
    delete_workflows
else
    echo -e "${STEPS} 不删除工作流"
fi
