#!/usr/bin/env bash

# Set default value
delete_releases="false"
delete_tags="false"
prerelease_option="all"
releases_keep_latest="90"
releases_keep_keyword=()
delete_workflows="false"
workflows_keep_latest="90"
workflows_keep_keyword=()
out_log="false"
github_per_page="100"
github_max_page="100"
max_releases_fetch="100"
max_workflows_fetch="100"

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

init_var() {
    echo -e "${STEPS} Start Initializing Variables..."

    # Install the necessary dependent packages
    sudo apt-get -qq update && sudo apt-get -qq install -y jq curl

    # If it is followed by [ : ], it means that the option requires a parameter value
    get_all_ver="$(getopt "r:a:t:p:l:w:s:d:k:o:g:R:W:" "${@}")"

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
        -R | --max_releases_fetch)
            if [[ -n "${2}" ]]; then
                max_releases_fetch="${2}"
                shift
            else
                error_msg "Invalid -R parameter [ ${2} ]!"
            fi
            ;;
        -W | --max_workflows_fetch)
            if [[ -n "${2}" ]]; then
                max_workflows_fetch="${2}"
                shift
            else
                error_msg "Invalid -W parameter [ ${2} ]!"
            fi
            ;;
        *)
            error_msg "Invalid option [ ${1} ]!"
            ;;
        esac
        shift
    done

    echo -e "${INFO} repo: [ ${repo} ]"
    echo -e "${INFO} delete_releases: [ ${delete_releases} ]"
    echo -e "${INFO} delete_tags: [ ${delete_tags} ]"
    echo -e "${INFO} prerelease_option: [ ${prerelease_option} ]"
    echo -e "${INFO} releases_keep_latest: [ ${releases_keep_latest} ]"
    echo -e "${INFO} releases_keep_keyword: [ $(echo ${releases_keep_keyword[@]} | xargs) ]"
    echo -e "${INFO} delete_workflows: [ ${delete_workflows} ]"
    echo -e "${INFO} workflows_keep_latest: [ ${workflows_keep_latest} ]"
    echo -e "${INFO} workflows_keep_keyword: [ $(echo ${workflows_keep_keyword[@]} | xargs) ]"
    echo -e "${INFO} out_log: [ ${out_log} ]"
    echo -e "${INFO} max_releases_fetch: [ ${max_releases_fetch} ]"
    echo -e "${INFO} max_workflows_fetch: [ ${max_workflows_fetch} ]"
    echo -e ""
}

# ... (其他函数保持不变)

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
