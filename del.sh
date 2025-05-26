#!/usr/bin/env bash

# Set default value
delete_releases="false"
delete_tags="false"
prerelease_option="all"
releases_keep_latest="90"
releases_keep_keyword=()
max_releases_fetch="200"
delete_workflows="false"
workflows_keep_latest="90"
workflows_keep_keyword=()
max_workflows_fetch="200"
out_log="false"
github_per_page="100"  # 每次请求获取的数量
github_max_page="100"  # 最大请求页数

# Set font color
STEPS="[\033[95m STEPS \033[0m]"
INFO="[\033[94m INFO \033[0m]"
NOTE="[\033[93m NOTE \033[0m]"
ERROR="[\033[91m ERROR \033[0m]"
SUCCESS="[\033[92m SUCCESS \033[0m]"

#==============================================================================================

error_msg() {
    echo -e "${ERROR} ${1}"
    exit 1
}

# 验证布尔值
validate_boolean() {
    local var="$1" param_name="$2"
    if [[ ! "$var" =~ ^(true|false)$ ]]; then
        error_msg "Invalid value for $param_name: must be 'true' or 'false'"
    fi
}

# 验证正整数（1-1000）
validate_positive_integer() {
    local var="$1" param_name="$2" max="$3"
    if ! [[ "$var" =~ ^[1-9][0-9]*$ ]]; then
        error_msg "Invalid value for $param_name: must be a positive integer"
    fi
    if [[ "$var" -gt "$max" ]]; then
        error_msg "Invalid value for $param_name: maximum value is $max"
    fi
}

init_var() {
    echo -e "${STEPS} Start Initializing Variables..."

    # Install the necessary dependent packages
    sudo apt-get -qq update && sudo apt-get -qq install -y jq curl

    # If it is followed by [ : ], it means that the option requires a parameter value
    get_all_ver="$(getopt "r:a:t:p:l:w:c:s:d:k:o:h:g:" "${@}")"

    while [[ -n "${1}" ]]; do
        case "${1}" in
        -r | --repo)
            if [[ -n "${2}" ]]; then
                repo="${2}"
                shift
            else
                error_msg "Invalid -r parameter [ ${2} ]!"
            fi
            ;;
        -a | --delete_releases)
            if [[ -n "${2}" ]]; then
                delete_releases="${2}"
                shift
            else
                error_msg "Invalid -a parameter [ ${2} ]!"
            fi
            ;;
        -t | --delete_tags)
            if [[ -n "${2}" ]]; then
                delete_tags="${2}"
                shift
            else
                error_msg "Invalid -t parameter [ ${2} ]!"
            fi
            ;;
        -p | --prerelease_option)
            if [[ -n "${2}" ]]; then
                prerelease_option="${2}"
                shift
            else
                error_msg "Invalid -p parameter [ ${2} ]!"
            fi
            ;;
        -l | --releases_keep_latest)
            if [[ -n "${2}" ]]; then
                releases_keep_latest="${2}"
                shift
            else
                error_msg "Invalid -l parameter [ ${2} ]!"
            fi
            ;;
        -w | --releases_keep_keyword)
            if [[ -n "${2}" ]]; then
                IFS="/" read -r -a releases_keep_keyword <<< "${2}"
                shift
            else
                error_msg "Invalid -w parameter [ ${2} ]!"
            fi
            ;;
        -c | --max_releases_fetch)
            if [[ -n "${2}" ]]; then
                max_releases_fetch="${2}"
                shift
            else
                error_msg "Invalid -c parameter [ ${2} ]!"
            fi
            ;;
        -s | --delete_workflows)
            if [[ -n "${2}" ]]; then
                delete_workflows="${2}"
                shift
            else
                error_msg "Invalid -s parameter [ ${2} ]!"
            fi
            ;;
        -d | --workflows_keep_latest)
            if [[ -n "${2}" ]]; then
                workflows_keep_latest="${2}"
                shift
            else
                error_msg "Invalid -d parameter [ ${2} ]!"
            fi
            ;;
        -k | --workflows_keep_keyword)
            if [[ -n "${2}" ]]; then
                IFS="/" read -r -a workflows_keep_keyword <<< "${2}"
                shift
            else
                error_msg "Invalid -k parameter [ ${2} ]!"
            fi
            ;;
        -o | --out_log)
            if [[ -n "${2}" ]]; then
                out_log="${2}"
                shift
            else
                error_msg "Invalid -o parameter [ ${2} ]!"
            fi
            ;;
        -g | --gh_token)
            if [[ -n "${2}" ]]; then
                gh_token="${2}"
                shift
            else
                error_msg "Invalid -g parameter [ ${2} ]!"
            fi
            ;;
        -h | --max_workflows_fetch)
            if [[ -n "${2}" ]]; then
                max_workflows_fetch="${2}"
                shift
            else
                error_msg "Invalid -h parameter [ ${2} ]!"
            fi
            ;;
        *)
            error_msg "Invalid option [ ${1} ]!"
            ;;
        esac
        shift
    done

    # 参数验证
    validate_boolean "$delete_releases" "delete_releases"
    validate_boolean "$delete_tags" "delete_tags"
    validate_boolean "$delete_workflows" "delete_workflows"
    validate_boolean "$out_log" "out_log"
    
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
    echo -e "${STEPS} Start querying the releases list..."

    # Create a file to store the results
    all_releases_list="json_api_releases"
    echo "" >"${all_releases_list}"
    
    # 计算需要请求的总页数
    total_pages=$(( (max_releases_fetch + github_per_page - 1) / github_per_page ))
    if [[ "$total_pages" -gt "$github_max_page" ]]; then
        total_pages="$github_max_page"
        echo -e "${NOTE} Maximum pages limited to $github_max_page"
    fi

    # Get the release list
    current_count=0
    for (( page=1; page<=total_pages; page++ )); do
        response="$(
            curl -s -L -f \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/releases?per_page=${github_per_page}&page=${page}"
        )" || {
            echo -e "${ERROR} Failed to fetch releases from GitHub API (page $page)"
            break
        }

        # Get the number of results returned by the current page
        get_results_length="$(echo "${response}" | jq '. | length')"
        echo -e "${INFO} (1.1.${page}) Query the [ ${page}th ] page and return [ ${get_results_length} ] results."

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
        # Remove empty lines
        sed -i '/^[[:space:]]*$/d' "${all_releases_list}"

        # Print the result log
        actual_count=$(cat "${all_releases_list}" | wc -l)
        echo -e "${INFO} (1.3.1) The api.github.com for releases request successfully."
        echo -e "${INFO} (1.3.2) Total releases fetched: [ ${actual_count} / ${max_releases_fetch} ]"
        [[ "${out_log}" == "true" ]] && {
            echo -e "${INFO} (1.3.3) All releases list:\n$(cat ${all_releases_list})"
        }
    else
        echo -e "${NOTE} (1.3.4) The releases list is empty. skip."
    fi
}

out_releases_list() {
    echo -e "${STEPS} Start outputting the releases list..."

    if [[ -s "${all_releases_list}" ]]; then
        # Filter based on the prerelease option(all/false/true)
        if [[ "${prerelease_option}" == "all" ]]; then
            echo -e "${NOTE} (1.4.1) Do not filter the prerelease option. skip."
        elif [[ "${prerelease_option}" == "false" ]]; then
            echo -e "${INFO} (1.4.2) Filter the prerelease option: [ false ]"
            cat ${all_releases_list} | jq -r '.prerelease' | grep -w "true" | while read line; do sed -i "/${line}/d" ${all_releases_list}; done
        elif [[ "${prerelease_option}" == "true" ]]; then
            echo -e "${INFO} (1.4.3) Filter the prerelease option: [ true ]"
            cat ${all_releases_list} | jq -r '.prerelease' | grep -w "false" | while read line; do sed -i "/${line}/d" ${all_releases_list}; done
        else
            error_msg "Invalid prerelease option [ ${prerelease_option} ]!"
        fi
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} (1.4.4) Current releases list:\n$(cat ${all_releases_list})"
    else
        echo -e "${NOTE} (1.4.5) The releases list is empty. skip."
    fi

    # Match tags that need to be filtered
    keep_releases_keyword_list="json_keep_releases_keyword_list"
    if [[ "${#releases_keep_keyword[@]}" -ge "1" && -s "${all_releases_list}" ]]; then
        # Match tags that meet the criteria
        echo -e "${INFO} (1.5.1) Filter tags keywords: [ $(echo ${releases_keep_keyword[@]} | xargs) ]"
        for keyword in "${releases_keep_keyword[@]}"; do
            cat ${all_releases_list} | jq -r '.tag_name' | grep -E "${keyword}" >>${keep_releases_keyword_list}
        done
        [[ "${out_log}" == "true" && -s "${keep_releases_keyword_list}" ]] && {
            echo -e "${INFO} (1.5.2) List of tags that meet the criteria:\n$(cat ${keep_releases_keyword_list})"
        }

        # Remove the tags that need to be kept
        [[ -s "${keep_releases_keyword_list}" ]] && {
            cat ${keep_releases_keyword_list} | while read line; do sed -i "/${line}/d" ${all_releases_list}; done
            echo -e "${INFO} (1.5.3) The tags keywords filtering successfully."
        }

        # List of remaining tags after filtering.
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} (1.5.4) Current releases list:\n$(cat ${all_releases_list})"
    else
        echo -e "${NOTE} (1.5.5) The filter keyword is empty. skip."
    fi

    # Match the latest tags that need to be kept
    keep_releases_list="json_keep_releases_list"
    if [[ -s "${all_releases_list}" ]]; then
        if [[ "${releases_keep_latest}" -eq "0" ]]; then
            echo -e "${INFO} (1.6.1) Delete all releases."
        else
            # Generate a list of tags that need to be kept
            cat ${all_releases_list} | head -n ${releases_keep_latest} >${keep_releases_list}
            echo -e "${INFO} (1.6.2) The keep tags list is generated successfully."
            [[ "${out_log}" == "true" && -s "${keep_releases_list}" ]] && {
                echo -e "${INFO} (1.6.3) The keep tags list:\n$(cat ${keep_releases_list})"
            }

            # Remove releases that need to be kept from the full list
            sed -i "1,${releases_keep_latest}d" ${all_releases_list}
        fi
    else
        echo -e "${NOTE} (1.6.4) The releases list is empty. skip."
    fi

    # Delete list
    if [[ -s "${all_releases_list}" ]]; then
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} (1.6.5) Delete releases list:\n$(cat ${all_releases_list})"
    else
        echo -e "${NOTE} (1.6.6) The delete releases list is empty. skip."
    fi

    echo -e ""
}

del_releases_file() {
    echo -e "${STEPS} Start deleting releases files..."

    # Delete releases
    if [[ -s "${all_releases_list}" && -n "$(cat ${all_releases_list} | jq -r .id)" ]]; then
        total=$(cat ${all_releases_list} | wc -l)
        count=0
        
        cat ${all_releases_list} | jq -r .id | while read release_id; do
            count=$((count + 1))
            echo -e "${INFO} (1.7.1) Deleting release ${count}/${total}: ID=${release_id}"
            
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/releases/${release_id}")
                
            if [[ "$response" -eq 204 ]]; then
                echo -e "${SUCCESS} (1.7.2) Release ${count}/${total} deleted successfully"
            else
                echo -e "${ERROR} (1.7.3) Failed to delete release ${count}/${total}: HTTP ${response}"
            fi
        done
        echo -e "${SUCCESS} (1.7.4) Releases deletion completed"
    else
        echo -e "${NOTE} (1.7.5) No releases need to be deleted. skip."
    fi

    echo -e ""
}

del_releases_tags() {
    echo -e "${STEPS} Start deleting tags..."

    # Delete the tags associated with releases
    if [[ "${delete_tags}" == "true" && -s "${all_releases_list}" && -n "$(cat ${all_releases_list} | jq -r .tag_name)" ]]; then
        total=$(cat ${all_releases_list} | wc -l)
        count=0
        
        cat ${all_releases_list} | jq -r .tag_name | while read tag_name; do
            count=$((count + 1))
            echo -e "${INFO} (1.8.1) Deleting tag ${count}/${total}: ${tag_name}"
            
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/git/refs/tags/${tag_name}")
                
            if [[ "$response" -eq 204 ]]; then
                echo -e "${SUCCESS} (1.8.2) Tag ${count}/${total} deleted successfully"
            else
                echo -e "${ERROR} (1.8.3) Failed to delete tag ${count}/${total}: HTTP ${response}"
            fi
        done
        echo -e "${SUCCESS} (1.8.4) Tags deletion completed"
    else
        echo -e "${NOTE} (1.8.5) No tags need to be deleted. skip."
    fi

    echo -e ""
}

get_workflows_list() {
    echo -e "${STEPS} Start querying the workflows list..."

    # Create a file to store the results
    all_workflows_list="json_api_workflows"
    echo "" >"${all_workflows_list}"
    
    # 计算需要请求的总页数
    total_pages=$(( (max_workflows_fetch + github_per_page - 1) / github_per_page ))
    if [[ "$total_pages" -gt "$github_max_page" ]]; then
        total_pages="$github_max_page"
        echo -e "${NOTE} Maximum pages limited to $github_max_page"
    fi

    # Get the workflows list
    current_count=0
    for (( page=1; page<=total_pages; page++ )); do
        response="$(
            curl -s -L -f \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/actions/runs?per_page=${github_per_page}&page=${page}"
        )" || {
            echo -e "${ERROR} Failed to fetch workflows from GitHub API (page $page)"
            break
        }

        # Get the number of results returned by the current page
        get_results_length="$(echo "${response}" | jq -r '.workflow_runs | length')"
        echo -e "${INFO} (2.1.${page}) Query the [ ${page}th ] page and return [ ${get_results_length} ] results."

        # 计算还需要获取的数量
        remaining=$(( max_workflows_fetch - current_count ))
        if [[ "$remaining" -le 0 ]]; then
            break
        fi

        # 限制本次处理的数量
        if [[ "$get_results_length" -gt "$remaining" ]]; then
            echo "${response}" |
                jq -c ".workflow_runs[0:'$remaining'] | select(.status != \"in_progress\") | {date: .updated_at, id: .id, name: .name}" \
                    >>"${all_workflows_list}"
            current_count=$(( current_count + remaining ))
            break
        else
            echo "${response}" |
                jq -c '.workflow_runs[] | select(.status != "in_progress") | {date: .updated_at, id: .id, name: .name}' \
                    >>"${all_workflows_list}"
            current_count=$(( current_count + get_results_length ))
        fi

        # 如果当前页返回的数量小于请求数量，说明已获取全部数据
        if [[ "$get_results_length" -lt "$github_per_page" ]]; then
            break
        fi
    done

    if [[ -s "${all_workflows_list}" ]]; then
        # Remove empty lines
        sed -i '/^[[:space:]]*$/d' "${all_workflows_list}"

        # Print the result log
        actual_count=$(cat "${all_workflows_list}" | wc -l)
        echo -e "${INFO} (2.3.1) The api.github.com for workflows request successfully."
        echo -e "${INFO} (2.3.2) Total workflows fetched: [ ${actual_count} / ${max_workflows_fetch} ]"
        [[ "${out_log}" == "true" ]] && {
            echo -e "${INFO} (2.3.3) All workflows runs list:\n$(cat ${all_workflows_list})"
        }
    else
        echo -e "${NOTE} (2.3.4) The workflows list is empty. skip."
    fi
}

out_workflows_list() {
    echo -e "${STEPS} Start outputting the workflows list..."

    # The workflows containing keywords that need to be keep
    keep_keyword_workflows_list="json_keep_keyword_workflows_list"
    # Remove workflows that match keywords and need to be kept
    if [[ "${#workflows_keep_keyword[@]}" -ge "1" && -s "${all_workflows_list}" ]]; then
        # Match the list of workflows that meet the keywords
        echo -e "${INFO} (2.4.1) Filter Workflows runs keywords: [ $(echo ${workflows_keep_keyword[@]} | xargs) ]"
        for keyword in "${workflows_keep_keyword[@]}"; do
            cat ${all_workflows_list} | jq -r '.name' | grep -E "${keyword}" >>${keep_keyword_workflows_list}
        done
        [[ "${out_log}" == "true" && -s "${keep_keyword_workflows_list}" ]] && {
            echo -e "${INFO} (2.4.2) List of Workflows runs that meet the criteria:\n$(cat ${keep_keyword_workflows_list})"
        }

        # Remove the workflows that need to be kept
        [[ -s "${keep_keyword_workflows_list}" ]] && {
            cat ${keep_keyword_workflows_list} | while read line; do sed -i "/${line}/d" ${all_workflows_list}; done
            echo -e "${INFO} (2.4.3) The keyword filtering successfully."
        }

        # List of remaining workflows after filtering by keywords
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} (2.4.4) Current workflows runs list:\n$(cat ${all_workflows_list})"
    else
        echo -e "${NOTE} (2.4.5) The filter keyword is empty. skip."
    fi

    # Generate a keep list of workflows
    keep_workflows_list="json_keep_workflows_list"
    if [[ -s "${all_workflows_list}" ]]; then
        if [[ "${workflows_keep_latest}" -eq "0" ]]; then
            echo -e "${INFO} (2.5.1) Delete all workflows runs."
        else
            # Sort workflows by date and keep the latest ones
            cat ${all_workflows_list} | jq -s 'sort_by(.date | fromdateiso8601) | reverse' >${keep_workflows_list}
            head -n ${workflows_keep_latest} ${keep_workflows_list} >${keep_workflows_list}.tmp
            mv ${keep_workflows_list}.tmp ${keep_workflows_list}

            echo -e "${INFO} (2.5.2) The keep workflows runs list is generated successfully."
            [[ "${out_log}" == "true" && -s "${keep_workflows_list}" ]] && {
                echo -e "${INFO} (2.5.3) Keep workflows list:\n$(cat ${keep_workflows_list})"
            }

            # Remove workflows that need to be kept from the full list
            sed -i "1,${workflows_keep_latest}d" ${all_workflows_list}
        fi
    else
        echo -e "${NOTE} (2.5.4) The workflows runs list is empty. skip."
    fi

    # Delete list
    if [[ -s "${all_workflows_list}" ]]; then
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} (2.5.5) Delete workflows list:\n$(cat ${all_workflows_list})"
    else
        echo -e "${NOTE} (2.5.6) The delete workflows list is empty. skip."
    fi

    echo -e ""
}

del_workflows_runs() {
    echo -e "${STEPS} Start deleting workflows runs..."

    # Delete workflows runs
    if [[ -s "${all_workflows_list}" && -n "$(cat ${all_workflows_list} | jq -r .id)" ]]; then
        total=$(cat ${all_workflows_list} | wc -l)
        count=0
        
        cat ${all_workflows_list} | jq -r .id | while read run_id; do
            count=$((count + 1))
            echo -e "${INFO} (2.6.1) Deleting workflow run ${count}/${total}: ID=${run_id}"
            
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                -H "Authorization: Bearer ${gh_token}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${repo}/actions/runs/${run_id}")
                
            if [[ "$response" -eq 204 ]]; then
                echo -e "${SUCCESS} (2.6.2) Workflow run ${count}/${total} deleted successfully"
            else
                echo -e "${ERROR} (2.6.3) Failed to delete workflow run ${count}/${total}: HTTP ${response}"
            fi
        done
        echo -e "${SUCCESS} (2.6.4) Workflow runs deletion completed"
    else
        echo -e "${NOTE} (2.6.5) No Workflows runs need to be deleted. skip."
    fi

    echo -e ""
}

# Show welcome message
echo -e "${STEPS} Welcome to use the delete older releases and workflow runs tool!"

# Perform related operations in sequence
init_var "${@}"

# Delete release
if [[ "${delete_releases}" == "true" ]]; then
    get_releases_list
    out_releases_list
    del_releases_file
    del_releases_tags
else
    echo -e "${STEPS} Do not delete releases and tags."
fi

# Delete workflows
if [[ "${delete_workflows}" == "true" ]]; then
    get_workflows_list
    out_workflows_list
    del_workflows_runs
else
    echo -e "${STEPS} Do not delete workflows."
fi

# Show all process completion prompts
echo -e "${SUCCESS} All process completed successfully."
wait
