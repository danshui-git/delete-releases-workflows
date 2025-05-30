#!/usr/bin/env bash

# ---
# 用于GitHub，删除旧发布和旧的工作流
# 原作者: ophub
# 相关链接: https://github.com/ophub/delete-releases-workflows
# ---
# 由281677160二次修改，修改内容如下
# 1、改进参数传递方式和检查
# 2、修改原保留工作流天数,改成保留时间靠前的个数
# 3、增加每次检测工作流或者发布的总数量,避免一次删除过多造成时间过长
# 4、修复工作流列表显示为空和关键词过滤失败的问题
# ---

# 设置默认值
github_per_page="100"  # 每次请求获取的数量
github_max_page="100"  # 最大请求页数

# 设置提示字体颜色
STEPS="[\033[95m 执行 \033[0m]"
INFO="[\033[94m 信息 \033[0m]"
NOTE="[\033[93m 结果 \033[0m]"
ERROR="[\033[91m 错误 \033[0m]"
SUCCESS="[\033[92m 成功 \033[0m]"

# 错误则停止运行函数
error_msg() {
    echo -e "${ERROR} ${1}"
    exit 1
}

# 验证开关值函数
validate_boolean() {
    local var="$1" param_name="$2"
    if [[ ! "$var" =~ ^(true|false)$ ]]; then
        error_msg "参数 $param_name 的值: $var 无效，必须是 'true' 或 'false'"
    fi
}

# 验证预发版选项函数
validate_prerelease() {
    local var="$1" param_name="$2"
    if [[ ! "$var" =~ ^(true|false|all)$ ]]; then
        error_msg "参数 $param_name 的值: $var 无效，必须是 'true', 'false' 或 'all'."
    fi
}

# 验证正整数函数（1-1000）
validate_positive_integer() {
    local var="$1" param_name="$2" max="$3"
    if ! [[ "$var" =~ ^[0-9][0-9]*$ ]]; then
        error_msg "参数 $param_name 的值: $var 无效，必须是正整数"
    fi
    if [[ "$var" -gt "$max" ]]; then
        error_msg "参数 $param_name 的值: $var 无效，最大值为 $max"
    fi
}

# 安全转义关键词为正则表达式
escape_regex() {
    local text="$1"
    # 转义正则特殊字符: . ^ $ * + ? ( ) [ ] { } | \
    echo "$text" | sed -e 's/[.[\*^$+?(){}\\|]/\\&/g'
}

init_var() {
    echo -e "${STEPS} 开始初始化变量..."

    # 安装必要的依赖包
    sudo apt-get -qq update && sudo apt-get -qq install -y jq curl

    # 验证必需参数
    [[ -z "${gh_token}" ]] && error_msg "必须附加[ gh_token ]参数，且参数为正确密钥"
    [[ -z "${delete_releases}" ]] && error_msg "必须附加[ delete_releases ]参数，且参数设置为 'true' 或 'false'"
    [[ -z "${delete_workflows}" ]] && error_msg "必须附加[ delete_workflows ]参数，且参数设置为 'true' 或 'false'"

    # 验证各种参数开关
    validate_boolean "$delete_releases" "delete_releases"
    validate_boolean "$delete_tags" "delete_tags"
    validate_boolean "$delete_workflows" "delete_workflows"
    validate_boolean "$out_log" "out_log"

    # 验证预发版选项参数
    validate_prerelease "${prerelease_option}" "prerelease_option"

    # 验证整数值参数
    validate_positive_integer "$releases_keep_latest" "releases_keep_latest" 1000
    validate_positive_integer "$workflows_keep_latest" "workflows_keep_latest" 1000
    validate_positive_integer "$max_releases_fetch" "max_releases_fetch" 1000
    validate_positive_integer "$max_workflows_fetch" "max_workflows_fetch" 1000
    
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

get_releases_list() {
    echo -e "${STEPS} 开始查询发布列表..."

    # 创建文件存储结果
    all_releases_list="json_api_releases"
    echo "" >"${all_releases_list}"
    
    # 计算需要请求的总页数
    total_pages=$(( (max_releases_fetch + github_per_page - 1) / github_per_page ))
    if [[ "$total_pages" -gt "$github_max_page" ]]; then
        total_pages="$github_max_page"
        echo -e "${NOTE} 最大页数限制为 $github_max_page"
    fi

    # 获取发布列表
    current_count=0
    for (( page=1; page<=total_pages; page++ )); do
        response="$(
            curl -s -L -f \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/releases?per_page=${github_per_page}&page=${page}"
        )" || {
            echo -e "${ERROR} 从 GitHub API 获取发布失败 (第 $page 页)"
            break
        }

        # 获取当前页返回的结果数量
        get_results_length="$(echo "${response}" | jq '. | length')"
        echo -e "${INFO} (1.1.${page}) 查询 [ 第 ${page} 页 ]，返回 [ ${get_results_length} ] 条结果。"

        # 计算还需要获取的数量
        remaining=$(( max_releases_fetch - current_count ))
        if [[ "$remaining" -le 0 ]]; then
            break
        fi

        # 限制本次处理的数量
        if [[ "$get_results_length" -gt "$remaining" ]]; then
            echo "${response}" |
                jq -s '.[] | sort_by(.published_at)|reverse | .[0:'$remaining']' |
                jq -c '.[] | {date: .published_at, id: .id, prerelease: .prerelease, tag_name: .tag_name}' \
                    >>"${all_releases_list}"
            current_count=$(( current_count + remaining ))
            break
        else
            echo "${response}" |
                jq -s '.[] | sort_by(.published_at)|reverse' |
                jq -c '.[] | {date: .published_at, id: .id, prerelease: .prerelease, tag_name: .tag_name}' \
                    >>"${all_releases_list}"
            current_count=$(( current_count + get_results_length ))
        fi

        # 如果当前页返回的数量小于请求数量，说明已获取全部数据
        if [[ "$get_results_length" -lt "$github_per_page" ]]; then
            break
        fi
    done

    if [[ -s "${all_releases_list}" ]]; then
        # 删除空行
        sed -i '/^[[:space:]]*$/d' "${all_releases_list}"

        # 打印结果日志
        actual_count=$(cat "${all_releases_list}" | wc -l)
        echo -e "${INFO} (1.3.1) 获取发布信息请求成功。"
        echo -e "${INFO} (1.3.2) 获取到的总发布数量: [ ${actual_count} / ${max_releases_fetch} ]"
        [[ "${out_log}" == "true" ]] && {
            echo -e "${INFO} (1.3.3) 所有发布列表:\n$(cat ${all_releases_list})"
        }
    else
        echo -e "${NOTE} (1.3.4) 发布列表为空，跳过。"
    fi
}

out_releases_list() {
    echo -e "${STEPS} 开始输出发布列表..."

    if [[ -s "${all_releases_list}" ]]; then
        echo -e "${INFO} (1.4.0) 过滤前发布列表行数: $(cat ${all_releases_list} | wc -l)"
        
        # 根据预发布选项过滤(all/false/true)
        if [[ "${prerelease_option}" == "all" ]]; then
            echo -e "${NOTE} (1.4.1) 不过滤预发布选项，检查全部发布信息。"
        elif [[ "${prerelease_option}" == "false" ]]; then
            echo -e "${INFO} (1.4.2) 过滤预发版选项: [ false ]"
            # 使用jq过滤而非sed，避免误删
            jq -s 'map(select(.prerelease == false))' "${all_releases_list}" > "${all_releases_list}.tmp"
            mv "${all_releases_list}.tmp" "${all_releases_list}"
        elif [[ "${prerelease_option}" == "true" ]]; then
            echo -e "${INFO} (1.4.3) 过滤预发版选项: [ true ]"
            jq -s 'map(select(.prerelease == true))' "${all_releases_list}" > "${all_releases_list}.tmp"
            mv "${all_releases_list}.tmp" "${all_releases_list}"
        fi
        
        echo -e "${INFO} (1.4.4) 预发布过滤后发布列表行数: $(cat ${all_releases_list} | wc -l)"
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} (1.4.5) 当前发布列表:\n$(cat ${all_releases_list})"
    else
        echo -e "${NOTE} (1.4.6) 发布列表为空，跳过。"
        return
    fi

    # 匹配需要过滤的标签
    keep_releases_keyword_list="json_keep_releases_keyword_list"
    if [[ "${#releases_keep_keyword[@]}" -ge "1" && -s "${all_releases_list}" ]]; then
        echo -e "${INFO} (1.5.1) 过滤标签关键词: [ $(echo ${releases_keep_keyword[@]} | xargs) ]"
        echo "" > "${keep_releases_keyword_list}"
        
        # 收集所有需要保留的标签
        for keyword in "${releases_keep_keyword[@]}"; do
            escaped_keyword=$(escape_regex "$keyword")
            echo -e "${INFO} (1.5.2) 处理关键词: [ ${keyword} ] -> [ ${escaped_keyword} ]"
            cat "${all_releases_list}" | jq -r '.tag_name' | grep -E "${escaped_keyword}" >> "${keep_releases_keyword_list}"
        done
        
        if [[ -s "${keep_releases_keyword_list}" ]]; then
            echo -e "${INFO} (1.5.3) 符合条件的标签数量: $(cat ${keep_releases_keyword_list} | wc -l)"
            [[ "${out_log}" == "true" ]] && {
                echo -e "${INFO} (1.5.4) 符合条件的标签列表:\n$(cat ${keep_releases_keyword_list})"
            }

            # 删除需要保留的标签（逐行处理，避免正则冲突）
            while read -r line; do
                escaped_line=$(escape_regex "$line")
                sed -i "/\"tag_name\": \"${escaped_line}\"/d" "${all_releases_list}"
            done < "${keep_releases_keyword_list}"
            
            echo -e "${SUCCESS} (1.5.5) 标签关键词过滤成功。剩余发布数量: $(cat ${all_releases_list} | wc -l)"
        else
            echo -e "${INFO} (1.5.6) 没有匹配到任何关键词标签。"
        fi
    else
        echo -e "${NOTE} (1.5.7) 关键字符为空，跳过过滤操作。"
    fi

    # 匹配需要保留的最新标签
    keep_releases_list="json_keep_releases_list"
    if [[ -s "${all_releases_list}" ]]; then
        if [[ "${releases_keep_latest}" -eq "0" ]]; then
            echo -e "${INFO} (1.6.1) 删除所有发布。"
        else
            # 生成需要保留的标签列表
            cat "${all_releases_list}" | head -n "${releases_keep_latest}" > "${keep_releases_list}"
            echo -e "${INFO} (1.6.2) 保留标签列表生成成功。保留数量: ${releases_keep_latest}"
            [[ "${out_log}" == "true" && -s "${keep_releases_list}" ]] && {
                echo -e "${INFO} (1.6.3) 保留标签列表:\n$(cat ${keep_releases_list})"
            }

            # 从全量列表中删除需要保留的发布
            sed -i "1,${releases_keep_latest}d" "${all_releases_list}"
            echo -e "${INFO} (1.6.4) 剩余待删除发布数量: $(cat ${all_releases_list} | wc -l)"
        fi
    else
        echo -e "${NOTE} (1.6.5) 发布列表为空，跳过。"
    fi

    # 删除列表
    if [[ -s "${all_releases_list}" ]]; then
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} (1.6.6) 删除发布列表:\n$(cat ${all_releases_list})"
    else
        echo -e "${NOTE} (1.6.7) 删除发布列表为空，跳过。"
    fi

    echo -e ""
}

del_releases_file() {
    echo -e "${STEPS} 开始删除发布文件..."

    # 删除发布
    if [[ -s "${all_releases_list}" && -n "$(cat ${all_releases_list} | jq -r .id)" ]]; then
        total=$(cat ${all_releases_list} | wc -l)
        count=0
        
        cat ${all_releases_list} | jq -r .id | while read release_id; do
            count=$((count + 1))
            echo -e "${INFO} (1.7.1) 正在删除发布 ${count}/${total}: ID=${release_id}"
            
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/releases/${release_id}")
                
            if [[ "$response" -eq 204 ]]; then
                echo -e "${SUCCESS} (1.7.2) 发布 ${count}/${total} 删除成功"
            else
                echo -e "${ERROR} (1.7.3) 删除发布 ${count}/${total} 失败: HTTP ${response}"
            fi
        done
        echo -e "${SUCCESS} (1.7.4) 发布删除完成"
    else
        echo -e "${NOTE} (1.7.5) 没有需要删除的发布，跳过。"
    fi

    echo -e ""
}

del_releases_tags() {
    echo -e "${STEPS} 开始删除标签..."

    # 删除与发布关联的标签
    if [[ "${delete_tags}" == "true" && -s "${all_releases_list}" && -n "$(cat ${all_releases_list} | jq -r .tag_name)" ]]; then
        total=$(cat ${all_releases_list} | wc -l)
        count=0
        
        cat ${all_releases_list} | jq -r .tag_name | while read tag_name; do
            count=$((count + 1))
            echo -e "${INFO} (1.8.1) 正在删除标签 ${count}/${total}: ${tag_name}"
            
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/git/refs/tags/${tag_name}")
                
            if [[ "$response" -eq 204 ]]; then
                echo -e "${SUCCESS} (1.8.2) 标签 ${count}/${total} 删除成功"
            else
                echo -e "${ERROR} (1.8.3) 删除标签 ${count}/${total} 失败: HTTP ${response}"
            fi
        done
        echo -e "${SUCCESS} (1.8.4) 标签删除完成"
    else
        echo -e "${NOTE} (1.8.5) 没有需要删除的标签，跳过。"
    fi

    echo -e ""
}

get_workflows_list() {
    echo -e "${STEPS} 开始查询工作流列表..."

    # 创建文件存储结果
    all_workflows_list="json_api_workflows"
    echo "" >"${all_workflows_list}"
    
    # 计算需要请求的总页数
    total_pages=$(( (max_workflows_fetch + github_per_page - 1) / github_per_page ))
    if [[ "$total_pages" -gt "$github_max_page" ]]; then
        total_pages="$github_max_page"
        echo -e "${NOTE} 最大页数限制为 $github_max_page"
    fi

    # 获取工作流列表
    current_count=0
    for (( page=1; page<=total_pages; page++ )); do
        response="$(
            curl -s -L -f \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/actions/runs?per_page=${github_per_page}&page=${page}"
        )" || {
            echo -e "${ERROR} 从 GitHub API 获取工作流失败 (第 $page 页)"
            break
        }

        # 获取当前页返回的结果数量
        get_results_length="$(echo "${response}" | jq -r '.workflow_runs | length')"
        echo -e "${INFO} (2.1.${page}) 查询 [ 第 ${page} 页 ]，返回 [ ${get_results_length} ] 条结果。"

        # 计算还需要获取的数量
        remaining=$(( max_workflows_fetch - current_count ))
        if [[ "$remaining" -le 0 ]]; then
            break
        fi

        # 限制本次处理的数量
        if [[ "$get_results_length" -gt "$remaining" ]]; then
            echo "${response}" |
                jq -c ".workflow_runs[:$remaining] | 
                      map(select(.status != \"in_progress\" and .status != \"queued\")) | 
                      sort_by(.updated_at | fromdateiso8601) | reverse | 
                      .[] | {date: .updated_at, id: .id, name: .name}" \
                    >>"${all_workflows_list}"
            current_count=$(( current_count + remaining ))
            break
        else
            echo "${response}" |
                jq -c '.workflow_runs[] | 
                      select(.status != "in_progress" and .status != "queued") | 
                      sort_by(.updated_at | fromdateiso8601) | reverse | 
                      .[] | {date: .updated_at, id: .id, name: .name}' \
                    >>"${all_workflows_list}"
            current_count=$(( current_count + get_results_length ))
        fi

        # 如果当前页返回的数量小于请求数量，说明已获取全部数据
        if [[ "$get_results_length" -lt "$github_per_page" ]]; then
            break
        fi
    done

    if [[ -s "${all_workflows_list}" ]]; then
        # 删除空行
        sed -i '/^[[:space:]]*$/d' "${all_workflows_list}"

        # 打印结果日志
        actual_count=$(cat "${all_workflows_list}" | wc -l)
        echo -e "${INFO} (2.3.1) 获取工作流信息请求成功。"
        echo -e "${INFO} (2.3.2) 获取到的总工作流数量: [ ${actual_count} / ${max_workflows_fetch} ]"
        [[ "${out_log}" == "true" ]] && {
            echo -e "${INFO} (2.3.3) 所有工作流运行列表:\n$(cat ${all_workflows_list})"
        }
    else
        echo -e "${NOTE} (2.3.4) 工作流列表为空，跳过。"
    fi
}

out_workflows_list() {
    echo -e "${STEPS} 开始输出工作流列表..."

    if [[ -s "${all_workflows_list}" ]]; then
        echo -e "${INFO} (2.4.0) 过滤前工作流列表行数: $(cat ${all_workflows_list} | wc -l)"
        
        # 包含需要保留关键词的工作流
        keep_keyword_workflows_list="json_keep_keyword_workflows_list"
        # 删除匹配关键词需要保留的工作流
        if [[ "${#workflows_keep_keyword[@]}" -ge "1" && -s "${all_workflows_list}" ]]; then
            # 匹配符合关键词的工作流列表
            echo -e "${INFO} (2.4.1) 过滤工作流运行关键词: [ $(echo ${workflows_keep_keyword[@]} | xargs) ]"
            echo "" > "${keep_keyword_workflows_list}"
            
            for keyword in "${workflows_keep_keyword[@]}"; do
                escaped_keyword=$(escape_regex "$keyword")
                echo -e "${INFO} (2.4.2) 处理关键词: [ ${keyword} ] -> [ ${escaped_keyword} ]"
                cat "${all_workflows_list}" | jq -r '.name' | grep -E "${escaped_keyword}" >> "${keep_keyword_workflows_list}"
            done
            
            if [[ -s "${keep_keyword_workflows_list}" ]]; then
                echo -e "${INFO} (2.4.3) 符合条件的工作流数量: $(cat ${keep_keyword_workflows_list} | wc -l)"
                [[ "${out_log}" == "true" ]] && {
                    echo -e "${INFO} (2.4.4) 符合条件的工作流列表:\n$(cat ${keep_keyword_workflows_list})"
                }

                # 删除需要保留的工作流（逐行处理，避免正则冲突）
                while read -r line; do
                    escaped_line=$(escape_regex "$line")
                    sed -i "/\"name\": \"${escaped_line}\"/d" "${all_workflows_list}"
                done < "${keep_keyword_workflows_list}"
                
                echo -e "${SUCCESS} (2.4.5) 关键词过滤成功。剩余工作流数量: $(cat ${all_workflows_list} | wc -l)"
            else
                echo -e "${INFO} (2.4.6) 没有匹配到任何关键词工作流。"
            fi
        else
            echo -e "${NOTE} (2.4.7) 关键字符为空，跳过过滤操作。"
        fi

        # 生成需要保留的工作流列表
        keep_workflows_list="json_keep_workflows_list"
        if [[ -s "${all_workflows_list}" ]]; then
            if [[ "${workflows_keep_latest}" -eq "0" ]]; then
                echo -e "${INFO} (2.5.1) 删除所有工作流运行。"
            else
                # 按日期排序并保留最新的工作流
                cp "${all_workflows_list}" "${keep_workflows_list}"
                # 使用jq确保日期排序正确
                jq -s 'sort_by(.date | fromdateiso8601) | reverse' "${keep_workflows_list}" > "${keep_workflows_list}.tmp"
                mv "${keep_workflows_list}.tmp" "${keep_workflows_list}"
                
                head -n "${workflows_keep_latest}" "${keep_workflows_list}" > "${keep_workflows_list}.tmp"
                mv "${keep_workflows_list}.tmp" "${keep_workflows_list}"

                echo -e "${INFO} (2.5.2) 保留工作流运行列表生成成功。保留数量: ${workflows_keep_latest}"
                [[ "${out_log}" == "true" && -s "${keep_workflows_list}" ]] && {
                    echo -e "${INFO} (2.5.3) 保留工作流列表:\n$(cat ${keep_workflows_list})"
                }

                # 从全量列表中删除需要保留的工作流
                sed -i "1,${workflows_keep_latest}d" "${all_workflows_list}"
                echo -e "${INFO} (2.5.4) 剩余待删除工作流数量: $(cat ${all_workflows_list} | wc -l)"
            fi
        else
            echo -e "${NOTE} (2.5.5) 工作流运行列表为空，跳过。"
        fi

        # 删除列表
        if [[ -s "${all_workflows_list}" ]]; then
            [[ "${out_log}" == "true" ]] && echo -e "${INFO} (2.5.6) 删除工作流列表:\n$(cat ${all_workflows_list})"
        else
            echo -e "${NOTE} (2.5.7) 删除工作流列表为空，跳过。"
        fi
    else
        echo -e "${NOTE} (2.4.8) 工作流列表为空，跳过。"
    fi

    echo -e ""
}

del_workflows_runs() {
    echo -e "${STEPS} 开始删除工作流运行..."

    # 删除工作流运行
    if [[ -s "${all_workflows_list}" && -n "$(cat ${all_workflows_list} | jq -r .id)" ]]; then
        total=$(cat ${all_workflows_list} | wc -l)
        count=0
        
        cat ${all_workflows_list} | jq -r .id | while read run_id; do
            count=$((count + 1))
            echo -e "${INFO} (2.6.1) 正在删除工作流运行 ${count}/${total}: ID=${run_id}"
            
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/actions/runs/${run_id}")
                
            if [[ "$response" -eq 204 ]]; then
                echo -e "${SUCCESS} (2.6.2) 工作流运行 ${count}/${total} 删除成功"
            else
                echo -e "${ERROR} (2.6.3) 删除工作流运行 ${count}/${total} 失败: HTTP ${response}"
            fi
        done
        echo -e "${SUCCESS} (2.6.4) 工作流运行删除完成"
    else
        echo -e "${NOTE} (2.6.5) 没有需要删除的工作流运行，跳过。"
    fi

    echo -e ""
}

# 显示欢迎信息
echo -e "${STEPS} 欢迎使用删除旧发布和工作流运行工具!"

# 检查变量
init_var "$@"

# 删除发布
if [[ "${delete_releases}" == "true" ]]; then
    get_releases_list
    out_releases_list
    del_releases_file
    del_releases_tags
else
    echo -e "${STEPS} 不删除发布和标签。"
fi

# 删除工作流
if [[ "${delete_workflows}" == "true" ]]; then
    get_workflows_list
    out_workflows_list
    del_workflows_runs
else
    echo -e "${STEPS} 不删除工作流。"
fi

# 显示所有流程完成提示
echo -e "${SUCCESS} 所有流程执行成功。"
wait
