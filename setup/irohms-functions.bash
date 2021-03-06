#! /usr/bin/env bash

# shellcheck disable=SC2153
IROHMS_DEV_DIR=$IROHMS_ENV_DIR/dev
IROHMS_SYSTEM_DIR=$IROHMS_ENV_DIR/system
export IROHMS_DEV_DIR
export IROHMS_SYSTEM_DIR

# ----------------------------------------------------------------------------------------------------
#                                        HELPER FUNCTIONS
# ----------------------------------------------------------------------------------------------------

function _list_subdirs
{
    fs=$(ls "$1")
    for f in $fs
    do
        if [ -d "$1"/"$f" ]
        then
            echo "$f"
        fi
    done
}

# ----------------------------------------------------------------------------------------------------
#                                       APT MIRROR SELECTION
# ----------------------------------------------------------------------------------------------------

function irohms-apt-select-mirror
{
    # Function to set the fastest APT mirror
    # It uses apt-select to generate a new sources.list, based on the current one.
    # All Arguments to this functions are passed on to apt-select, so check the
    # apt-select documentation for all options.
    hash pip2 2> /dev/null|| sudo apt-get install --assume-yes python-pip
    hash apt-select 2> /dev/null|| sudo -H pip2 install apt-select

    local mem_pwd=$PWD
    # shellcheck disable=SC2164
    cd /tmp
    local err_code
    apt-select "$@" 2> /dev/null
    err_code=$?
    if [ $err_code == 4 ]
    then
        echo -e "Fastest apt mirror is the current one"
    elif [ $err_code != 0 ]
    then
        echo -e "Non zero error code return by apt-select: $err_code"
    else
        echo -e "Updating the apt mirror with the fastest one"
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.bk
        sudo cp /tmp/sources.list /etc/apt/sources.list
        echo -e "Cleaning up existing apt lists in /var/lib/apt/lists"
        sudo rm -rf /var/lib/apt/lists/*
        echo -e "Running: sudo apt-get update -qq"
        sudo apt-get update -qq
    fi
    # shellcheck disable=SC2164
    cd "$mem_pwd"
}

# ----------------------------------------------------------------------------------------------------
#                                       GIT LOCAL HOUSEKEEPING
# ----------------------------------------------------------------------------------------------------

function _irohms-git-get-default-branch
{
    # Takes current dir in case $1 is empty
    local default_branch
    default_branch=$(git -C "$1" symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's@^origin/@@')
    [ -z "$default_branch" ] && default_branch=$(git -C "$1" remote show origin 2>/dev/null | grep HEAD | awk '{print $3}')
    echo "$default_branch"
}

function __irohms-git-checkout-default-branch
{
    local default_branch
    default_branch=$(_irohms-git-get-default-branch)
    _git_remote_checkout origin "$default_branch"
}

function _irohms-git-checkout-default-branch
{
    _irohms-repos-do "__irohms-git-checkout-default-branch"
}

function _irohms-git-clean-local
{
    # Function to remove stale branches from a git repository (which should
    # either be the PWD or one of its parent directories). The function removes
    # stale branches in two layers. First it removes all branches that have been
    # merged in the remote, then it checks for unmerged branches that have been
    # deleted from the remote and prompts for confirmation before removal. If
    # the function is called with "--force-remove" flag, then no confirmation is asked

    local force_remove
    local error_code
    local stale_branches
    local repo_path
    repo_path="$PWD"
    local repo
    repo=$(basename "$repo_path")

    if [ -n "$1" ]
    then
        if [ "$1" == "--force-remove" ]
        then
            force_remove=true
        else
            echo -e "\e[31m[irohms-git-clean-local][Error] Unknown input argument '$1'. Only supported argument is '--force-remove' to forcefully remove unmerged stale branches\e[0m"
            return 1
        fi
    fi

    git fetch -p || { echo -e "\e[31m[irohms-git-clean-local] 'git fetch -p' failed in '$repo'.\e[0m"; return 1; }

    stale_branches=$(git branch --list --format "%(if:equals=[gone])%(upstream:track)%(then)%(refname)%(end)" \
| sed 's,^refs/heads/,,;/^$/d')

    [ -z "$stale_branches" ] && return 0

    # If the current branch is a stale branch then change to the default repo
    # branch before cleanup
    if [[ "$stale_branches" == *$(git rev-parse --abbrev-ref HEAD)* ]]
    then
        __irohms-git-checkout-default-branch

        git pull --ff-only --prune > /dev/null 2>&1
        error_code=$?

        if [ ! $error_code -eq 0 ]
        then
            echo -e "\e[31m[irohms-git-clean-local] Error pulling upstream on default branch of repository '$repo'. Cancelling branch cleanup.\e[0m"
            return 1
        fi
    fi

    local stale_branch
    local stale_branch_count=0
    local unmerged_stale_branches=""
    for stale_branch in $stale_branches
    do
        git branch -d "$stale_branch" > /dev/null 2>&1
        error_code=$?

        # If an error occured in safe deletion of a stale branch, add it to the
        # list of unmerged stale branches which are to be forcefully removed
        # upon confirmation by the user
        if [ ! $error_code -eq 0 ]
        then
            unmerged_stale_branches="${unmerged_stale_branches:+${unmerged_stale_branches} } $stale_branch"
        else
            ((stale_branch_count++))
            if [ $stale_branch_count -eq 1 ]
            then
                echo -e "\e[36m"
                echo -e "Removing stale branches:"
                echo -e "------------------------"
            fi
            echo -e "$stale_branch"
        fi
    done

    # Removal of unmerged stale branches. Not a default operation with the high
    # level command irohms-git-clean-local
    if [ -n "$unmerged_stale_branches" ]
    then
        unmerged_stale_branches=$(echo "$unmerged_stale_branches" | sed -e 's/^[[:space:]]*//' | tr " " "\n")

        # If force_remove is not true then echo the list of unmerged stale
        # branches and echo that the user needs to call the command with
        # --force-remove to remove these branches
        if [ ! "$force_remove" == "true" ]
        then
            echo -e "\e[33m"
            echo -e "Found unmerged stale branches:"
            echo -e "------------------------------"
            echo -e "$unmerged_stale_branches"
            echo
            echo -e "[irohms-git-clean-local] To remove these branches call the command with '--force-remove'"
            echo -e "\e[0m"

            return 0
        fi

        echo
        echo -e "Removing unmerged stale branches:"
        echo -e "---------------------------------"

        local unmerged_stale_branch
        for unmerged_stale_branch in $unmerged_stale_branches
        do
            git branch -D "$unmerged_stale_branch" > /dev/null 2>&1
            error_code=$?

            if [ ! $error_code -eq 0 ]
            then
                echo -e "\e[31m[irohms-git-clean-local] In repository '$repo' error deleting branch: $unmerged_stale_branch\e[0m"
            else
                echo -e "\e[36m$unmerged_stale_branch"
            fi
        done
    fi

    echo
    echo -e "[irohms-git-clean-local] Branch cleanup of repository '$repo' complete\e[0m"
    return 0
}

function irohms-git-clean-local
{
    # Run _irohms-git-clean-local on irohms-env, irohms-env-targets and all current environment
    # repositories safely when no input exists

    if [ -n "$1" ]
    then
        if [ "$1" != "--force-remove" ]
        then
            echo -e "[irohms-git-clean-local][Error] Unknown input argument '$1'. Only supported argument is '--force-remove' to forcefully remove unmerged stale branches"
            return 1
        fi
    fi

    _irohms-repos-do "_irohms-git-clean-local $*"
}

function __irohms-git-clean-local
{
    local IFS=$'\n'
    options="'--force-remove'"
    # shellcheck disable=SC2178
    mapfile -t COMPREPLY < <(compgen -W "$(echo -e "$options")" -- "$cur")
}
complete -F __irohms-git-clean-local irohms-git-clean-local
complete -F __irohms-git-clean-local _irohms-git-clean-local

# ----------------------------------------------------------------------------------------------------
#                                              SSH
# ----------------------------------------------------------------------------------------------------

function _git_split_url
{
    local url=$1

    local web_address
    local domain_name
    local repo_address
    if [[ "$url" == *"@"* ]] # SSH
    then
        web_address=${url#git@}
        domain_name=${web_address%%:*}
        repo_address=${web_address#*:}
    else
        web_address=${url#https://}
        domain_name=${web_address%%/*}
        repo_address=${web_address#*/}
    fi
    repo_address=${repo_address%.git}
    echo -e "$domain_name\t$repo_address"
}
export -f _git_split_url # otherwise not available in sourced files

function _git_https
{
    local url=$1
    [[ $url =~ ^https://.*\.git$ ]] && echo "$url" && return 0

    local output
    output=$(_git_split_url "$url")

    local array
    read -r -a array <<< "$output"
    local domain_name=${array[0]}
    local repo_address=${array[1]}

    echo "https://$domain_name/$repo_address.git"
}
export -f _git_https # otherwise not available in sourced files

function _git_ssh
{
    local url=$1
    [[ $url =~ ^git@.*\.git$ ]] && echo "$url" && return 0

    local output
    output=$(_git_split_url "$url")

    local array
    read -r -a array <<< "$output"
    local domain_name=${array[0]}
    local repo_address=${array[1]}

    echo "git@$domain_name:$repo_address.git"
}
export -f _git_ssh # otherwise not available in sourced files

function _irohms_git_https_or_ssh
{
    local input_url=$1
    local output_url

    # TODO: Remove the use of IROHMS_USE_SSH when migration to IROHMS_GIT_USE_SSH is complete
    [[ -v "IROHMS_USE_SSH" ]] && test_var="IROHMS_USE_SSH"

    [[ -v "IROHMS_GIT_USE_SSH" ]] && test_var="IROHMS_GIT_USE_SSH"

    [[ "$input_url" == *"github"* ]] && [[ -v "IROHMS_GITHUB_USE_SSH" ]] && test_var="IROHMS_GITHUB_USE_SSH"
    [[ "$input_url" == *"gitlab"* ]] && [[ -v "IROHMS_GITLAB_USE_SSH" ]] && test_var="IROHMS_GITLAB_USE_SSH"

    if [[ "${!test_var}" == "true" ]]
    then
        output_url=$(_git_ssh "$input_url")
    else
        output_url=$(_git_https "$input_url")
    fi

    echo "$output_url"
}
export -f _irohms_git_https_or_ssh # otherwise not available in sourced files

# ----------------------------------------------------------------------------------------------------
#                                            IROHMS-MAKE
# ----------------------------------------------------------------------------------------------------

function irohms-make
{
    if [ -n "$IROHMS_ROS_DISTRO" ] && [ -d "$IROHMS_SYSTEM_DIR" ]
    then
        local build_tool=""
        if [ -f "$IROHMS_SYSTEM_DIR"/devel/.built_by ]
        then
            build_tool=$(cat "$IROHMS_SYSTEM_DIR"/devel/.built_by)
        fi
        case $build_tool in
        'catkin build')
            catkin build --workspace "$IROHMS_SYSTEM_DIR" "$@"
            ;;
        '')
            catkin config --init --mkdirs --workspace "$IROHMS_SYSTEM_DIR" --extend /opt/ros/"$IROHMS_ROS_DISTRO" -DCMAKE_BUILD_TYPE=RelWithDebInfo
            catkin build --workspace "$IROHMS_SYSTEM_DIR" "$@"
            touch "$IROHMS_SYSTEM_DIR"/devel/.catkin # hack to allow overlaying to this ws while being empty
            ;;
        *)
            echo -e "\e$build_tool is not supported (anymore), use catkin tools\e[0m"
            return 1
            ;;
        esac
    fi
}
export -f irohms-make

function _irohms-make
{
    local cur=${COMP_WORDS[COMP_CWORD]}

    mapfile -t COMPREPLY < <(compgen -W "$(_list_subdirs "$IROHMS_SYSTEM_DIR"/src)" -- "$cur")
}

complete -F _irohms-make irohms-make

function irohms-make-dev
{
    if [ -n "$IROHMS_ROS_DISTRO" ] && [ -d "$IROHMS_DEV_DIR" ]
    then
        local build_tool=""
        if [ -f "$IROHMS_DEV_DIR"/devel/.built_by ]
        then
            build_tool=$(cat "$IROHMS_DEV_DIR"/devel/.built_by)
        fi
        case $build_tool in
        'catkin build')
            catkin build --workspace "$IROHMS_DEV_DIR" "$@"
            ;;
        '')
            catkin config --init --mkdirs --workspace "$IROHMS_DEV_DIR" --extend "$IROHMS_SYSTEM_DIR"/devel -DCMAKE_BUILD_TYPE=RelWithDebInfo
            catkin build --workspace "$IROHMS_DEV_DIR" "$@"
            touch "$IROHMS_DEV_DIR"/devel/.catkin # hack to allow overlaying to this ws while being empty
            ;;
        *)
            echo -e "\e$build_tool is not supported (anymore), use catkin tools\e[0m"
            return 1
            ;;
        esac
    fi
}
export -f irohms-make-dev

function _irohms-make-dev
{
    local cur=${COMP_WORDS[COMP_CWORD]}

    mapfile -t COMPREPLY < <(compgen -W "$(_list_subdirs "$IROHMS_DEV_DIR"/src)" -- "$cur")
}
complete -F _irohms-make-dev irohms-make-dev

# ----------------------------------------------------------------------------------------------------
#                                              IROHMS-DEV
# ----------------------------------------------------------------------------------------------------

function irohms-dev
{
    if [ -z "$1" ]
    then
        _list_subdirs "$IROHMS_DEV_DIR"/src
        return 0
    fi

    for pkg in "$@"
    do
        if [ ! -d "$IROHMS_SYSTEM_DIR"/src/"$pkg" ]
        then
            echo "[irohms-dev] '$pkg' does not exist in the system workspace."
        elif [ -d "$IROHMS_DEV_DIR"/src/"$pkg" ]
        then
            echo "[irohms-dev] '$pkg' is already in the dev workspace."
        else
            ln -s "$IROHMS_SYSTEM_DIR"/src/"$pkg" "$IROHMS_DEV_DIR"/src/"$pkg"
        fi
    done

    # Call rospack such that the linked directories are indexed
    rospack profile &> /dev/null
}

function irohms-dev-clean
{
    for f in $(_list_subdirs "$IROHMS_DEV_DIR"/src)
    do
        # Test if f is a symbolic link
        if [[ -L $IROHMS_DEV_DIR/src/$f ]]
        then
            echo "Cleaned '$f'"
            rm "$IROHMS_DEV_DIR"/src/"$f"
        fi
    done

    rm -rf "$IROHMS_DEV_DIR"/devel/share
    rm -rf "$IROHMS_DEV_DIR"/devel/etc
    rm -rf "$IROHMS_DEV_DIR"/devel/include
    rm -rf "$IROHMS_DEV_DIR"/devel/lib
    rm -rf "$IROHMS_DEV_DIR"/build
}

function _irohms-dev
{
    local cur=${COMP_WORDS[COMP_CWORD]}

    mapfile -t COMPREPLY < <(compgen -W "$(_list_subdirs "$IROHMS_SYSTEM_DIR"/src)" -- "$cur")
}
complete -F _irohms-dev irohms-dev

# ----------------------------------------------------------------------------------------------------
#                                             IROHMS-STATUS
# ----------------------------------------------------------------------------------------------------

function _robocup_branch_allowed
{
    local branch=$1
    local robocup_branch
    robocup_branch=$(_irohms_get_robocup_branch)
    [ -n "$robocup_branch" ] && [ "$branch" == "$robocup_branch" ] && return 0
    # else
    return 1
}

function _irohms_get_robocup_branch
{
    [ -f "$IROHMS_DIR"/user/config/robocup ] && cat "$IROHMS_DIR"/user/config/robocup
}

function _irohms-repo-status
{
    local name=$1
    local pkg_dir=$2

    if [ ! -d "$pkg_dir" ]
    then
        return 1
    fi

    local status=
    local vctype=

    # Try git
    if git -C "$pkg_dir" rev-parse --git-dir > /dev/null 2>&1
    then
        # Is git
        local res

        if res=$(git -C "$pkg_dir" status . --short --branch 2>&1)
        then
            if echo "$res" | grep -q -E 'behind|ahead' # Check if behind or ahead of branch
            then
                status=$res
            else
                status=$(git -C "$pkg_dir" status . --short)
            fi

            local current_branch
            current_branch=$(git -C "$pkg_dir" rev-parse --abbrev-ref HEAD)

            local test_branches=""

            # Add branch specified by target
            local target_branch version_cache_file
            version_cache_file="$IROHMS_ENV_DIR/.env/version_cache/$(git -C "$pkg_dir" rev-parse --show-toplevel 2>/dev/null)"
            [ -f "$version_cache_file" ] && target_branch=$(cat "$version_cache_file")
            [ -n "$target_branch" ] && test_branches="${test_branches:+${test_branches} }$target_branch"

            # Add default branch
            local default_branch
            default_branch=$(_irohms-git-get-default-branch "$pkg_dir")
            [ -n "$default_branch" ] && test_branches="${test_branches:+${test_branches} }$default_branch"

            # Add robocup branch
            local robocup_branch
            robocup_branch=$(_irohms_get_robocup_branch)
            [ -n "$robocup_branch" ] && test_branches="${test_branches:+${test_branches} }$robocup_branch"

            local allowed="false"
            for test_branch in $test_branches
            do
                if [ "$test_branch" == "$current_branch" ]
                then
                    [ -z "$status" ] && return 0
                    # else
                    allowed="true"
                    break
                fi
            done
            [ "$allowed" != "true" ] && echo -e "\033[1m$name\033[0m is on branch '$current_branch'"
        fi
        vctype=git
    elif [ -d "$pkg_dir"/.svn ]
    then
        status=$(svn status "$pkg_dir")
        vctype=svn
    elif [ -d "$pkg_dir"/.hg ]
    then
        status=$(hg --cwd "$pkg_dir" status .)
        vctype=hg
    else
        vctype=unknown
    fi

    if [ -n "$vctype" ]
    then
        if [ -n "$status" ]
        then
            echo -e ""
            echo -e "\033[38;5;1mM  \033[0m($vctype) \033[1m$name\033[0m"
            echo -e "--------------------------------------------------"
            echo -e "$status"
            echo -e "--------------------------------------------------"
        fi
    fi
}

# ----------------------------------------------------------------------------------------------------

function _irohms-dir-status
{
    [ -d "$1" ] || return 1

    local fs
    fs=$(ls "$1")
    for f in $fs
    do
        pkg_dir=$1/$f
        _irohms-repo-status "$f" "$pkg_dir"
    done
}

# ----------------------------------------------------------------------------------------------------

function irohms-status
{
    _irohms-dir-status "$IROHMS_SYSTEM_DIR"/src
    _irohms-repo-status "irohms-env" "$IROHMS_DIR"
    _irohms-repo-status "irohms-env-targets" "$IROHMS_ENV_TARGETS_DIR"
}

# ----------------------------------------------------------------------------------------------------

function irohms-git-status
{
    for pkg_dir in "$IROHMS_SYSTEM_DIR"/src/*/
    do
        pkg=$(basename "$pkg_dir")

        if branch=$(git -C "$pkg_dir" rev-parse --abbrev-ref HEAD 2>&1)
        then
            hash=$(git -C "$pkg_dir" rev-parse --short HEAD)
            printf "\e[0;36m%-20s\033[0m %-15s %s\n" "$branch" "$hash" "$pkg"
        fi
    done
}

# ----------------------------------------------------------------------------------------------------
#                                              IROHMS-REVERT
# ----------------------------------------------------------------------------------------------------

function irohms-revert
{
    human_time="$*"

    for pkg_dir in "$IROHMS_SYSTEM_DIR"/src/*/
    do
        pkg=$(basename "$pkg_dir")

        branch=$(git -C "$pkg_dir" rev-parse --abbrev-ref HEAD 2>&1)
        if branch=$(git -C "$pkg_dir" rev-parse --abbrev-ref HEAD 2>&1) && [ "$branch" != "HEAD" ]
        then
            new_hash=$(git -C "$pkg_dir"  rev-list -1 --before="$human_time" "$branch")
            current_hash=$(git -C "$pkg_dir"  rev-parse HEAD)

            if git -C "$pkg_dir"  diff -s --exit-code "$new_hash" "$current_hash"
            then
                newtime=$(git -C "$pkg_dir"  show -s --format=%ci)
                printf "\e[0;36m%-20s\033[0m %-15s \e[1m%s\033[0m %s\n" "$branch is fine" "$new_hash" "$newtime" "$pkg"
            else
                git -C "$pkg_dir"  checkout -q "$new_hash"
                newbranch=$(git -C "$pkg_dir"  rev-parse --abbrev-ref HEAD 2>&1)
                newtime=$(git -C "$pkg_dir"  show -s --format=%ci)
                echo "$branch" > "$pkg_dir/.do_not_commit_this"
                printf "\e[0;36m%-20s\033[0m %-15s \e[1m%s\033[0m %s\n" "$newbranch based on $branch" "$new_hash" "$newtime" "$pkg"
            fi
        else
            echo "Package $pkg could not be reverted, current state: $branch"
        fi
    done
}

# ----------------------------------------------------------------------------------------------------
#                                              IROHMS-REVERT-UNDO
# ----------------------------------------------------------------------------------------------------

function irohms-revert-undo
{
    for pkg_dir in "$IROHMS_SYSTEM_DIR"/src/*/
    do
        pkg=$(basename "$pkg_dir")

        if [ -f "$pkg_dir/.do_not_commit_this" ]
        then
            echo "$pkg"
            git -C "$pkg_dir" checkout "$(cat "$pkg_dir"/.do_not_commit_this)"
            rm "$pkg_dir/.do_not_commit_this"
        fi
    done
    irohms-git-status
}

# ----------------------------------------------------------------------------------------------------
#                                              IROHMS-GET
# ----------------------------------------------------------------------------------------------------

function _irohms_show_file
{
    if [ -n "$2" ]
    then
        echo -e "\033[1m[$1] $2\033[0m"
        echo "--------------------------------------------------"
        if hash pygmentize 2> /dev/null
        then
            pygmentize -g "$IROHMS_ENV_TARGETS_DIR"/"$1"/"$2"
        else
            cat "$IROHMS_ENV_TARGETS_DIR"/"$1"/"$2"
        fi
        echo "--------------------------------------------------"
    else
        echo -e "_irohms_show_file requires target_name and relative file_path in target"
        return 1
    fi
}

function __irohms_irohms_generate_setup_file
{
    # Check whether this target was already added to the setup
    if [[ "$IROHMS_SETUP_TARGETS" == *" $1 "* ]];
    then
        return 0
    fi

    IROHMS_SETUP_TARGETS=" $1$IROHMS_SETUP_TARGETS"

    # Check if the dependency file exists. If not, return
    if [ ! -f "$irohms_dependencies_dir"/"$1" ]
    then
        return 0
    fi

    # Recursively add a setup for each dependency
    deps=$(cat "$irohms_dependencies_dir"/"$1")
    for dep in $deps
    do
        # You shouldn't depend on yourself
        if [ "$1" != "$dep" ]
        then
            __irohms_irohms_generate_setup_file "$dep"
        fi
    done

    local irohms_setup_file=$IROHMS_ENV_TARGETS_DIR/$1/setup
    if [ -f "$irohms_setup_file" ]
    then
        echo "source $irohms_setup_file" >> "$IROHMS_ENV_DIR"/.env/setup/target_setup.bash
    fi
}

function _irohms_generate_setup_file
{
    mkdir -p "$IROHMS_ENV_DIR"/.env/setup
    echo "# This file was auto-generated by irohms-get. Do not change this file." > "$IROHMS_ENV_DIR"/.env/setup/target_setup.bash

    local irohms_dependencies_dir="$IROHMS_ENV_DIR"/.env/dependencies

    if [ -d "$irohms_dependencies_dir" ]
    then
        local installed_targets
        installed_targets=$(ls "$IROHMS_ENV_DIR"/.env/installed)
        local IROHMS_SETUP_TARGETS=" "
        for t in $installed_targets
        do
            __irohms_irohms_generate_setup_file "$t"
        done
    fi
}

function _irohms_remove_recursively
{
    if [ -z "$1" ] || [ -n "$2" ]
    then
        echo "_irohms_remove_recursively requires and accepts one target"
        echo "provided arguments: $*"
        return 1
    fi

    local target=$1
    local irohms_dependencies_dir="$IROHMS_ENV_DIR"/.env/dependencies
    local irohms_dependencies_on_dir="$IROHMS_ENV_DIR"/.env/dependencies-on
    local error_code=0

    # If packages depend on the target to be removed, just remove the installed status.
    if [ -f "$irohms_dependencies_on_dir"/"$target" ]
    then
        if [[ -n $(cat "$irohms_dependencies_on_dir"/"$target") ]]
        then
            # depend-on is not empty, so removing the installed status
            echo "[irohms-get] Other targets still depend on $target, so ignoring it"
            return 0
        else
            # depend-on is empty, so remove it and continue to actual removing of the target
            echo "[irohms-get] Deleting empty depend-on file of: $target"
            rm -f "$irohms_dependencies_on_dir"/"$target"
        fi
    fi

    # If no packages depend on this target, remove it and its dependcies.
    if [ -f "$irohms_dependencies_dir"/"$target" ]
    then
        # Iterate over all depencies of target, which is removed.
        while read -r dep
        do
            # Target is removed, so remove yourself from depend-on files of deps
            local dep_dep_on_file="$irohms_dependencies_on_dir"/"$dep"
            local tmp_file=/tmp/temp_depend_on
            if [ -f "$dep_dep_on_file" ]
            then
                while read -r line
                do
                    [[ $line != "$target" ]] && echo "$line"
                done <"$dep_dep_on_file" >"$tmp_file"
                mv "$tmp_file" "$dep_dep_on_file"
                echo "[irohms-get] Removed '$target' from depend-on file of '$dep'"
            else
                echo "$target depends on $dep, so $dep_dep_on_file should exist with $target in it"
                error_code=1
            fi

            # Actually remove the deps
            local dep_error
            _irohms_remove_recursively "$dep"
            dep_error=$?
            if [ $dep_error -gt 0 ]
            then
                error_code=1
            fi

        done < "$irohms_dependencies_dir"/"$target"
        rm -f "$irohms_dependencies_dir"/"$target"
    else
        echo "[irohms-get] No depencies file exist for target: $target"
    fi

    echo "[irohms-get] Fully uninstalled $target and its dependencies"
    return $error_code
}

function irohms-get
{
    if [ -z "$1" ]
    then
        # shellcheck disable=SC1078,SC1079
        echo """irohms-get is a tool for installing and removing packages.

    Usage: irohms-get COMMAND [ARG1 ARG2 ...]

    Possible commands:

        dep              - Shows target dependencies
        install          - Installs a package
        update           - Updates currently installed packages
        remove           - Removes installed package
        list-installed   - Lists all manually installed packages
        show             - Show the contents of (a) package(s)

    Possible options:
        --debug          - Shows more debugging information
        --no-ros-deps    - Do not install ROS dependencies (Breaks the dependency tree, not all setup files will be sourced)
        --doc-depend     - Do install doc dependencies, overules config and --no-ros-deps
        --no-doc-depend  - Do not install doc dependencies, overules config
        --test-depend    - Do install test dependencies, overules config and --no-ros-deps
        --no-test-depend - Do not install test dependencies, overules config
        --branch=name    - Try to checkout this branch if exists

"""
        return 1
    fi

    local irohms_dep_dir=$IROHMS_ENV_DIR/.env/dependencies
    local irohms_installed_dir=$IROHMS_ENV_DIR/.env/installed

    local error_code=0

    local cmd=$1
    shift

    #Create btrfs snapshot if possible and usefull:
    if [[ "$cmd" =~ ^(install|update|remove)$ ]] && { df --print-type / | grep -q btrfs; }
    then
        sudo mkdir -p /snap/root
        sudo btrfs subvolume snapshot / /snap/root/"$(date +%Y-%m-%d_%H:%M:%S)"
    fi

    if [[ "$cmd" =~ ^(install|remove)$ && -z "$1" ]]
    then
       echo "Usage: irohms-get $cmd TARGET [TARGET2 ...]"
       return 1
    fi

    if [[ $cmd == "install" || $cmd == "update" ]]
    then
        if [[ $cmd == "update" ]]
        then
            for target in "$@"
            do
                #Skip options
                [[ $target = '--'* ]] && continue

                if [ -z "$(find "$IROHMS_ENV_DIR"/.env/dependencies -maxdepth 1 -name "$target" -type f -printf "%P ")" ]
                then
                    echo "[irohms-get] Package '$target' is not installed."
                    error_code=1
                fi
            done
        fi

        if [ $error_code -eq 0 ]
        then
            "$IROHMS_DIR"/installer/irohms-install.bash "$cmd" "$@"
            error_code=$?
            if [ $error_code -eq 0 ]
            then
                _irohms_generate_setup_file
                # shellcheck disable=SC1090
                source "$IROHMS_DIR"/setup.bash
            fi
        fi

        return $error_code
    elif [[ $cmd == "remove" ]]
    then
        local targets_to_remove=""
        for target in "$@"
        do
            local resolved_targets
            resolved_targets="$(find "$irohms_installed_dir" -maxdepth 1 -name "$target" -type f -printf "%P ")"
            if [ -z "$resolved_targets" ]
            then
                echo "[irohms-get] Package '$target' is not installed."
                error_code=1
            else
                targets_to_remove="${targets_to_remove:+$targets_to_remove }$resolved_targets"
            fi
        done

        if [ $error_code -gt 0 ]
        then
            echo ""
            echo "[irohms-get] No packages where removed."
            return $error_code;
        fi

        if [ -f /tmp/irohms_get_remove_lock ]
        then
            echo "[irohms-get] Can't execute 'remove' as an other run is still busy"
            echo "[irohms-get] If this keeps happening, excute: rm /tmp/irohms_get_remove_lock"
            return 1
        fi

        touch /tmp/irohms_get_remove_lock
        for target in $targets_to_remove
        do
            local target_error=0
            _irohms_remove_recursively "$target"
            target_error=$?
            if [ $target_error -gt 0 ]
            then
                error_code=1
                echo "[irohms-get] Problems during uninstalling $target"
            else
                rm "$irohms_installed_dir"/"$target"
                echo "[irohms-get] Succesfully uninstalled: $target"
            fi
        done

        if [ $error_code -eq 0 ]
        then
            echo "[irohms-get] Re-generating the target setup file"
            _irohms_generate_setup_file
        fi

        rm /tmp/irohms_get_remove_lock

        echo ""
        if [ -n "$2" ]
        then
            echo "[irohms-get] The packages were removed from the 'installed list' but still need to be deleted from your workspace."
        else
            echo "[irohms-get] The package was removed from the 'installed list' but still needs to be deleted from your workspace."
        fi
    elif [[ $cmd == "list-installed" ]]
    then
        if [[ "$1" == "-a" ]]
        then
            ls "$irohms_dep_dir"
        else
            ls "$IROHMS_ENV_DIR"/.env/installed
        fi
    elif [[ $cmd == "show" ]]
    then
        if [ -z "$1" ]
        then
            echo "[irohms-get](show) Provide at least one target name"
            return 1
        fi
        local firsttarget=true
        for target in "$@"
        do
            if [[ $firsttarget == false ]]
            then
                echo ""
            fi
            if [ ! -d "$IROHMS_ENV_TARGETS_DIR"/"$target" ]
            then
                echo "[irohms-get](show) '$target' is not a valid target"
                firsttarget=false
                continue
            fi

            local firstfile="true"
            local files
            mapfile -t files < <(find "$IROHMS_ENV_TARGETS_DIR"/"$target" -type f)

            # First show the common target files
            local main_target_files="install.yaml install.bash setup"
            for file in $main_target_files
            do
                for key in "${!files[@]}"
                do
                    if [ "${files[$key]}" == "$IROHMS_ENV_TARGETS_DIR"/"$target"/"$file" ]
                    then
                        if [[ $firstfile == false ]]
                        then
                            echo ""
                        fi
                        _irohms_show_file "$target" "$file"
                        firstfile=false
                        unset "files[$key]"
                        files=("${files[@]}")
                        break
                    fi
                done
            done

            # Show all remaining files
            for file in "${files[@]}"
            do
                if [[ $firstfile == false ]]
                then
                    echo ""
                fi
                _irohms_show_file "$target" "${file#*$IROHMS_ENV_TARGETS_DIR"/"$target/}"
                firstfile=false
            done
            firsttarget=false
        done

    elif [[ $cmd == "dep" ]]
    then
        "$IROHMS_DIR"/installer/irohms-get-dep.bash "$@"
    else
        echo "[irohms-get] Unknown command: '$cmd'"
        return 1
    fi
}

function _irohms-get
{
    local cur=${COMP_WORDS[COMP_CWORD]}

    if [ "$COMP_CWORD" -eq 1 ]
    then
        local IFS=$'\n'
        options="'dep '\n'install '\n'update '\n'remove '\n'list-installed '\n'show '"
        # shellcheck disable=SC2178
        mapfile -t COMPREPLY < <(compgen -W "$(echo -e "$options")" -- "$cur")
    else
        cmd=${COMP_WORDS[1]}
        if [[ $cmd == "install" ]]
        then
            local IFS=$'\n'
            # shellcheck disable=SC2178
            mapfile -t COMPREPLY < <(compgen -W "$(echo -e "$(find "$IROHMS_ENV_TARGETS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name ".*" -printf "%f\n" | sed "s/.*/'& '/g")\n'--debug '\n'--no-ros-deps '\n'--doc-depend '\n'--no-doc-depend '\n'--test-depend '\n'--no-test-depend '\n'--branch='")" -- "$cur")
        elif [[ $cmd == "dep" ]]
        then
            local IFS=$'\n'
            # shellcheck disable=SC2178
            mapfile -t COMPREPLY < <(compgen -W "$(echo -e "$(find "$IROHMS_ENV_DIR"/.env/dependencies -mindepth 1 -maxdepth 1 -type f -not -name ".*" -printf "%f\n" | sed "s/.*/'& '/g")\n'--plain '\n'--verbose '\n'--ros-only '\n'--all '\n'--level='")" -- "$cur")
        elif [[ $cmd == "update" ]]
        then
            local IFS=$'\n'
            # shellcheck disable=SC2178
            mapfile -t COMPREPLY < <(compgen -W "$(echo -e "$(find "$IROHMS_ENV_DIR"/.env/dependencies -mindepth 1 -maxdepth 1 -type f -not -name ".*" -printf "%f\n" | sed "s/.*/'& '/g")\n'--debug '\n'--no-ros-deps '\n'--doc-depend '\n'--no-doc-depend '\n'--test-depend '\n'--no-test-depend '\n'--branch='")" -- "$cur")
        elif [[ $cmd == "remove" ]]
        then
            local IFS=$'\n'
            # shellcheck disable=SC2178
            mapfile -t COMPREPLY < <(compgen -W "$(find "$IROHMS_ENV_DIR"/.env/installed -mindepth 1 -maxdepth 1 -type f -not -name ".*" -printf "%f\n" | sed "s/.*/'& '/g")" -- "$cur")
        elif [[ $cmd == "show" ]]
        then
            local IFS=$'\n'
            # shellcheck disable=SC2178
            mapfile -t COMPREPLY < <(compgen -W "$(find "$IROHMS_ENV_TARGETS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name ".*" -printf "%f\n" | sed "s/.*/'& '/g")" -- "$cur")
        else
            # shellcheck disable=SC2178
            COMPREPLY=""
        fi
    fi
}
complete -o nospace -F _irohms-get irohms-get

# ----------------------------------------------------------------------------------------------------
#                                             IROHMS-CHECKOUT
# ----------------------------------------------------------------------------------------------------

function irohms-checkout
{
    if [ -z "$1" ]
    then
        # shellcheck disable=SC1078,SC1079
        echo """Switches all packages to the given branch, if such a branch exists in that package. Usage:

    irohms-checkout BRANCH-NAME [option]

    options:
    --only-pks: irohms-env is not checked-out to the specified branch

"""
        return 1
    fi

    while test $# -gt 0
    do
        case "$1" in
            --only-pkgs) local NO_IROHMS_ENV="true"
            ;;
            --*) echo "unknown option $1"; exit 1;
            ;;
            *) local branch=$1
            ;;
        esac
        shift
    done

    fs=$(ls -d -1 "$IROHMS_SYSTEM_DIR"/src/**)
    if [ -z "$NO_IROHMS_ENV" ]
    then
        fs="$IROHMS_DIR $IROHMS_ENV_TARGETS_DIR $fs"
    fi
    for pkg_dir in $fs
    do
        pkg=${pkg_dir#$IROHMS_SYSTEM_DIR/src/}
        if [ -z "$NO_IROHMS_ENV" ]
        then
            if [[ $pkg =~ .irohms ]]
            then
                pkg="irohms-env"
            elif [[ $pkg =~ targets ]]
            then
                pkg="irohms-env-targets"
            fi
        fi

        if [ -d "$pkg_dir" ]
        then
            if git -C "$pkg_dir" rev-parse --quiet --verify origin/"$branch" 1>/dev/null
            then
                local current_branch
                current_branch=$(git -C "$pkg_dir" rev-parse --abbrev-ref HEAD)
                if [[ "$current_branch" == "$branch" ]]
                then
                    echo -e "\033[1m$pkg\033[0m: Already on branch $branch"
                else
                    local res _checkout_res _checkout_return _submodule_res _submodule_return
                    _checkout_res=$(git -C "$pkg_dir" checkout "$branch" 2>&1)
                    _checkout_return=$?
                    [ -n "$_checkout_res" ] && res="${res:+${res} }$_checkout_res"
                    _submodule_res=$(git -C "$pkg_dir" submodule update --init --recursive 2>&1)
                    # shellcheck disable=SC2034
                    _submodule_return=$?
                    [ -n "$_submodule_res" ] && res="${res:+${res} }$_submodule_res"

                    if [ "$_checkout_return" == 0 ] && [ -z "$_submodule_res" ]
                    then
                        echo -e "\033[1m$pkg\033[0m: checked-out $branch"
                    else
                        echo ""
                        echo -e "    \033[1m$pkg\033[0m"
                        echo "--------------------------------------------------"
                        echo -e "\033[38;5;1m$res\033[0m"
                        echo "--------------------------------------------------"
                    fi
                fi
            fi
        fi
    done
}

# ----------------------------------------------------------------------------------------------------
#                                              IROHMS-DATA
# ----------------------------------------------------------------------------------------------------

# shellcheck disable=SC1090
source "$IROHMS_DIR"/setup/irohms-data.bash

# ----------------------------------------------------------------------------------------------------
#                                             IROHMS-ROBOCUP
# ----------------------------------------------------------------------------------------------------

export IROHMS_ROBOCUP_BRANCH="rwc2019"

function _irohms-repos-do
{
    # Evaluates the command of the input for irohms-env, irohms-env-targets and all repo's of irohms-robotics.
    # The input can be multiple arguments, but if the input consists of multiple commands
    # seperated by ';' or '&&' the input needs to be captured in a string.

    local mem_pwd=$PWD

    { [ -n "$IROHMS_DIR" ] && cd "$IROHMS_DIR"; } || { echo -e "IROHMS_DIR '$IROHMS_DIR' does not exist"; return 1; }
    echo -e "\033[1m[irohms-env]\033[0m"
    eval "$@"

    { [ -n "$IROHMS_ENV_TARGETS_DIR" ] && cd "$IROHMS_ENV_TARGETS_DIR"; } || { echo -e "IROHMS_ENV_TARGETS_DIR '$IROHMS_ENV_TARGETS_DIR' does not exist"; return 1; }
    echo -e "\033[1m[irohms-env-targets]\033[0m"
    eval "$@"

    local repos_dir=$IROHMS_ENV_DIR/repos/github.com/irohms-robotics

    local fs
    fs=$(ls "$repos_dir")
    for repo in $fs
    do
        local repo_dir=$repos_dir/$repo

        if [ -d "$repo_dir" ]
        then
            cd "$repo_dir" || { echo -e "Directory '$IROHMS_ENV_TARGETS_DIR' does not exist"; return 1; }
            echo -e "\033[1m[${repo%.git}]\033[0m"
            eval "$@"
        fi
    done

    # shellcheck disable=SC2164
    cd "$mem_pwd"
}

function _irohms-add-git-remote
{
    local remote=$1
    local server=$2

    if [ -z "$2" ]
    then
        echo "Usage: _irohms-add-git-remote REMOTE SERVER

For example:

    _irohms-add-git-remote roboticssrv amigo@roboticssrv.local:
        "
        return 1
    fi

    if [ "$remote" == "origin" ]
    then
        echo -e "\033[1mYou are not allowed to change the remote: 'origin'\033[0m"
        return 1
    fi

    local output
    output="$(_git_split_url "$(git config --get remote.origin.url)")"
    local array
    read -r -a array <<< "$output"
    local repo_address=${array[1]}
    local url_extension="$repo_address.git"

    if [[ "$(git remote)" == *"$remote"* ]]
    then
        local current_url
        current_url=$(git config --get remote."$remote".url)
        if [[ "$current_url" == "$server$url_extension" ]]
        then
            echo -e "remote '$remote' exists with the same url"
            return 0
        fi

        git remote set-url "$remote" "$server$url_extension"
        echo -e "url of remote '$remote' is changed
    from: $current_url
    to: $server$url_extension"
        return 0
    fi
    git remote add "$remote" "$server$url_extension"

    echo -e "remote '$remote' added with url: $server$url_extension"
}

function irohms-add-git-remote
{
    if [ -z "$2" ]
    then
        echo "Usage: irohms-add-git-remote REMOTE SERVER

For example:

    irohms-add-git-remote roboticssrv amigo@roboticssrv.local:
        "
        return 1
    fi

    local remote=$1
    local server=$2

    if [ "$remote" == "origin" ]
    then
        echo -e "\033[1mYou are not allowed to change the remote: 'origin'\033[0m"
        return 1
    fi

    _irohms-repos-do "_irohms-add-git-remote $remote $server"
}

function __irohms-remove-git-remote
{
    local remote=$1

    if [ -z "$1" ]
    then
        echo "Usage: __irohms-remove-git-remote REMOTE

For example:

    __irohms-remove-git-remote roboticssrv
        "
        return 1
    fi

    if [ "$remote" == "origin" ]
    then
        echo -e "\033[1mYou are not allowed to remove the remote: 'origin'\033[0m"
        return 1
    fi

    if [[ "$(git remote)" == *"$remote"* ]]
    then
        git remote remove "$remote"
        echo -e "remote '$remote' is removed"
        return 0
    fi

    echo -e "remote '$remote' doesn't exist"
}

function _irohms-remove-git-remote
{
    if [ -z "$1" ]
    then
        echo "Usage: _irohms-remove-git-remote REMOTE

For example:

    _irohms-remove-git-remote roboticssrv
        "
        return 1
    fi

    local remote=$1

    if [ "$remote" == "origin" ]
    then
        echo -e "\033[1mYou are not allowed to remove the remote: 'origin'\033[0m"
        return 1
    fi

    _irohms-repos-do "__irohms-remove-git-remote $remote"
}

function _git_remote_checkout
{
    if [ -z "$2" ]
    then
        echo "Usage: _git_remote_checkout REMOTE BRANCH

For example:

    _git_remote_checkout roboticssrv robocup
        "
        return 1
    fi

    local remote=$1
    local branch=$2
    local exists
    exists=$(git show-ref refs/heads/"$branch")
    if [ -n "$exists" ]
    then
        git checkout "$branch"
        git branch -u "$remote"/"$branch" "$branch"
    else
        git checkout --track -b "$branch" "$remote"/"$branch"
    fi
}

function irohms-remote-checkout
{
    if [ -z "$2" ]
    then
        echo "Usage: irohms-remote-checkout REMOTE BRANCH

For example:

    irohms-remote-checkout roboticssrv robocup
        "
        return 1
    fi

    local remote=$1
    local branch=$2

    _irohms-repos-do "git fetch $remote; _git_remote_checkout $remote $branch"
}

function _irohms-robocup-remote-checkout
{
    if [ -z "$2" ]
    then
        echo "Usage: _irohms-robocup-remote-checkout REMOTE BRANCH

For example:

    _irohms-robocup-remote-checkout roboticssrv robocup
        "
        return 1
    fi

    local remote=$1
    local branch=$2

    git fetch "$remote"
    local current_remote
    current_remote=$(git for-each-ref --format='%(upstream:short)' "$(git symbolic-ref -q HEAD)" | awk -F/ '{print $1}')
    if [ "$current_remote" != "$remote" ]
    then
        _git_remote_checkout "$remote" "$branch"
    fi
}

function irohms-robocup-remote-checkout
{
    # same functionality as irohms-remote-checkout, but no arguments needed
    # doesn't perform a checkout, when current branch is already setup
    # to the roboticssrv
    local remote="roboticssrv"
    local branch=$IROHMS_ROBOCUP_BRANCH

    _irohms-repos-do "_irohms-robocup-remote-checkout $remote $branch"
}

function _irohms-robocup-change-remote
{
    if [ -z "$2" ]
    then
        echo "Usage: _irohms-robocup-change-remote BRANCH REMOTE

For example:

    _irohms-robocup-change-remote robocup origin
        "
        return 1
    fi

    local branch=$1
    local remote=$2

    if [ -n "$(git show-ref refs/heads/"$branch")" ]
    then
        if [[ "$(git remote)" == *"$remote"* ]]
        then
            git fetch "$remote"
            if [[ "$(git branch -a)" == *"${remote}/${branch}"* ]]
            then
                git branch -u "$remote"/"$branch" "$branch"
            else
                echo -e "no branch: $branch on remote: $remote"
            fi
        else
            echo -e "no remote: $remote"
        fi
    else
        echo -e "no local branch: $branch"
    fi
}

function irohms-robocup-change-remote
{
    # This changes the remote of the 'BRANCH' branch to 'REMOTE'
    # After this, you local working copies may be behind what was fetched from REMOTE, so run a $ irohms-get update

    # for packages that have a REMOTE as a remote:
    # do a git fetch origin: git fetch
    # Change remote of branch 'BRANCH' to REMOTE: git branch -u REMOTE/BRANCH BRANCH

    if [ -z "$2" ]
    then
        echo "Usage: irohms-robocup-change-remote BRANCH REMOTE

For example:

    irohms-robocup-change-remote robocup origin
        "
        return 1
    fi

    local branch=$1
    local remote=$2

    _irohms-repos-do "_irohms-robocup-change-remote $branch $remote"
}

function irohms-robocup-ssh-copy-id
{
    ssh-copy-id amigo@roboticssrv.local
}

function _allow_robocup_branch
{
    # allow IROHMS_ROBOCUP_BRANCH as branch in irohms-status
    if [ ! -f "$IROHMS_DIR"/user/config/robocup ]
    then
        echo $IROHMS_ROBOCUP_BRANCH > "$IROHMS_DIR"/user/config/robocup
    fi
}

function _disallow_robocup_branch
{
    # disallow IROHMS_ROBOCUP_BRANCH as branch in irohms-status
    if [ -f "$IROHMS_DIR"/user/config/robocup ]
    then
        rm "$IROHMS_DIR"/user/config/robocup
    fi
}

function irohms-robocup-set-github
{
    irohms-robocup-change-remote $IROHMS_ROBOCUP_BRANCH origin
    _irohms-git-checkout-default-branch
    _disallow_robocup_branch
}

function irohms-robocup-set-roboticssrv
{
    irohms-add-git-remote roboticssrv amigo@roboticssrv.local:
    irohms-robocup-remote-checkout
    _allow_robocup_branch
}

function irohms-robocup-set-timezone-robocup
{
    sudo timedatectl set-timezone Australia/Sydney
}

function irohms-robocup-set-timezone-home
{
    sudo timedatectl set-timezone Europe/Amsterdam
}

function _ping_bool
{
    if ping -c 1 "$1" 1>/dev/null 2>/dev/null
    then
        return 0
    else
        return 1
    fi
}

function irohms-robocup-install-package
{
    local repos_dir=$IROHMS_ENV_DIR/repos/github.com/irohms-robotics
    local repo_dir=$repos_dir/${1}.git

    local mem_pwd=$PWD

    local remote="roboticssrv"
    local server="amigo@roboticssrv.local:"
    local branch=$IROHMS_ROBOCUP_BRANCH

    # If directory already exists, return
    [ -d "$repo_dir" ] && return 0

    git clone "$server"irohms-robotics/"$1".git "$repo_dir"

    [ ! -d "$repo_dir" ] && return 0
    # shellcheck disable=SC2164
    cd "$repo_dir"

    git remote rename origin $remote
    git remote add origin https://github.com/irohms-robotics/"$1".git

    # shellcheck disable=SC2164
    cd "$mem_pwd"

    if [ -f "$repo_dir/package.xml" ]
    then
        if [ ! -h "$IROHMS_ENV_DIR"/system/src/"$1" ]
        then
            ln -s "$repo_dir" "$IROHMS_ENV_DIR"/system/src/"$1"
        fi
    else
        # multiple packages in one repo
        local fs
        fs=$(find . -mindepth 1 -maxdepth 1 -type d -not -name ".*" -printf "%f\n")
        for pkg in $fs
        do
            local pkg_dir=$repo_dir/$pkg
            if [ -f "$pkg_dir/package.xml" ]
            then
                if [ ! -h "$IROHMS_ENV_DIR"/system/src/"$pkg" ]
                then
                    ln -s "$pkg_dir" "$IROHMS_ENV_DIR"/system/src/"$pkg"
                fi
            fi
        done
    fi

    # mark target as installed
    touch "$IROHMS_ENV_DIR"/.env/installed/ros-"$1"
}

function irohms-robocup-update
{
    _irohms-repos-do "git pull --ff-only"

    # Copy rsettings file
    if [ "$ROBOT_REAL" != "true" ]
    then
        rsettings_file=$IROHMS_ENV_TARGETS_DIR/irohms-common/rsettings_file
        if [ -f "$rsettings_file" ]
        then
            cp "$rsettings_file" "$IROHMS_DIR"/.rsettings
        fi
    fi
}

function irohms-robocup-set-apt-get-proxy
{
    sudo bash -c "echo 'Acquire::http::Proxy \"http://roboticssrv.wtb.irohms.nl:3142\";' > /etc/apt/apt.conf.d/01proxy"
}

function irohms-robocup-unset-apt-get-proxy
{
    sudo rm /etc/apt/apt.conf.d/01proxy
}
