#!/bin/bash
# vim: et sr sw=4 ts=4 smartindent:
# helper script to generate label data for docker image during building
#
# docker_build will generate an image tagged :candidate
#
# It is a post-step to tag that appropriately and push to repo

MIN_DOCKER=1.11.0
GIT_SHA_LEN=8
IMG_TAG=candidate

version_gt() {
    [[ "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" ]]
}

valid_docker_version() {
    v=$(docker --version | grep -Po '\b\d+\.\d+\.\d+\b')
    if version_gt $MIN_DOCKER $v
    then
        echo "ERROR: need min docker version $MIN_DOCKER" >&2
        return 1
    fi
}

create_dockerfile() {
    local go_ver=1.10
    local alpine_ver=3.7
    local url="https://github.com/docker-library/golang"
    local build_src=r/$go_ver/alpine$alpine_ver
    local df=$build_src/Dockerfile

    rm -rf r Dockerfile *.patch 2>/dev/null

    cp Dockerfile.tmpl Dockerfile

    ! git clone "$url" r && echo "ERROR: can't clone $url" && return 1

    ! modify_dockerfile "$df" && echo "ERROR: can't create Dockerfile" && return 1

    cp -a r/$go_ver/alpine$alpine_ver/. . || return 1

    rm -rf r
}

modify_dockerfile() {
    local f="$1"
    [[ ! -w $f ]] && echo "ERROR: can't write to $f" && return 1
    sed -i '/^FROM/d' $f || return 1
    sed -i '/^WORKDIR/d' $f || return 1

    sed -i '/apk del .build.deps/d' $f || return 1

    sed -i "/# INSERT-HERE/ r $f" Dockerfile || return 1

    rm $f || return 1
}

built_by() {
    local user="--UNKNOWN--"
    if [[ ! -z "${BUILD_URL}" ]]; then
        user="${BUILD_URL}"
    elif [[ ! -z "${AWS_PROFILE}" ]] || [[ ! -z "${AWS_ACCESS_KEY_ID}" ]]; then
        user="$(aws iam get-user --query 'User.UserName' --output text)@$HOSTNAME"
    else
        user="$(git config --get user.name)@$HOSTNAME"
    fi
    echo "$user"
}

git_uri(){
    git config remote.origin.url || echo 'no-remote'
}

git_sha(){
    git rev-parse --short=${GIT_SHA_LEN} --verify HEAD
}

git_branch(){
    r=$(git rev-parse --abbrev-ref HEAD)
    [[ -z "$r" ]] && echo "ERROR: no rev to parse when finding branch? " >&2 && return 1
    [[ "$r" == "HEAD" ]] && r="from-a-tag"
    echo "$r"
}

img_name(){
    (
        set -o pipefail;
        grep -Po '(?<=[nN]ame=")[^"]+' Dockerfile | head -n 1
    )
}

golang_version() {
    (
        set -o pipefail;
        grep -Po '(?<=GOLANG_VERSION )[\d\.]+' Dockerfile
    )
}

labels() {
    gov=$(golang_version) || return 1
    gu=$(git_uri) || return 1
    gs=$(git_sha) || return 1
    gb=$(git_branch) || return 1
    gt=$(git describe 2>/dev/null || echo "no-git-tag")
    bb=$(built_by) || return 1

    cat<<EOM
    --label version=$(date +'%Y%m%d%H%M%S')
    --label jinal--shah.golang_version=$gov
    --label jinal--shah.build_git_uri=$gu
    --label jinal--shah.build_git_sha=$gs
    --label jinal--shah.build_git_branch=$gb
    --label jinal--shah.build_git_tag=$gt
    --label jinal--shah.built_by="$bb"
EOM
}

docker_build(){

    valid_docker_version || return 1

    create_dockerfile || return 1

    labels=$(labels) || return 1
    n=$(img_name) || return 1

    echo "INFO: adding these labels:"
    echo "$labels"
    echo "INFO: building $n:$IMG_TAG"

    docker_gid=$(id -G docker)
    echo "... will set docker gid to $docker_gid"
    docker build --no-cache=true --force-rm $labels -t $n:$IMG_TAG .
}

docker_build
