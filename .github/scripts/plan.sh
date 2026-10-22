#!/usr/bin/env bash
# 解析 images.txt，生成 GitHub Actions matrix（每个镜像一个并行 job）
#
# 用法：
#   bash .github/scripts/plan.sh          # 本地调试，直接打印 matrix JSON
#   bash .github/scripts/plan.sh          # CI 中自动写入 $GITHUB_OUTPUT
#
# images.txt 语法：
#   [命名空间]                     段落头，之后所有镜像推到该命名空间
#   --space=xxx 镜像               单行指定命名空间，优先级高于段落
#   --platform=linux/arm64 镜像    指定架构（不写则整份 manifest list 一起搬）
#   --tag=xxx 镜像                 自定义目标 tag（覆盖镜像自带的 tag，digest 引用推荐用这个）
#   镜像[:tag]                     不写 tag 默认 latest
#   # 注释

set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

if [ ! -f images.txt ]; then
    echo "::error::找不到 images.txt"
    exit 1
fi

# 去掉行尾 \r 与首尾空白
trim() {
    local s="${1%$'\r'}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# 解析一行
# 输出: PULL_ARGS=() , PLATFORM , SPACE , TAG , IMAGE
parse_line() {
    local -a tokens
    read -r -a tokens <<< "$1"
    PULL_ARGS=()
    PLATFORM=""
    SPACE=""
    TAG=""
    IMAGE=""
    local i=0 n=${#tokens[@]} t
    while [ "$i" -lt "$n" ]; do
        t="${tokens[$i]}"
        case "$t" in
            --space|--namespace)
                i=$((i + 1)); SPACE="${tokens[$i]:-}"
                ;;
            --space=*|--namespace=*)
                SPACE="${t#*=}"
                ;;
            --tag)
                i=$((i + 1)); TAG="${tokens[$i]:-}"
                ;;
            --tag=*)
                TAG="${t#*=}"
                ;;
            --platform)
                PULL_ARGS+=("$t")
                i=$((i + 1)); PLATFORM="${tokens[$i]:-}"
                if [ -n "$PLATFORM" ]; then PULL_ARGS+=("$PLATFORM"); fi
                ;;
            --platform=*)
                PLATFORM="${t#*=}"
                PULL_ARGS+=("$t")
                ;;
            *)
                PULL_ARGS+=("$t")
                ;;
        esac
        i=$((i + 1))
    done
    if [ "${#PULL_ARGS[@]}" -gt 0 ]; then
        IMAGE="${PULL_ARGS[$((${#PULL_ARGS[@]} - 1))]}"
    fi
}

# 拆解镜像引用 -> IMAGE_NAME_TAG , NAME_SPACE , IMAGE_NAME
split_image() {
    local image="${1%%@*}"
    IMAGE_NAME_TAG="${image##*/}"
    local path="${image%/*}"
    if [ "$path" = "$image" ]; then
        NAME_SPACE=""
    elif [[ "$path" == */* ]]; then
        NAME_SPACE="${path#*/}"
    else
        NAME_SPACE="$path"
    fi
    IMAGE_NAME="${IMAGE_NAME_TAG%%:*}"
}

# 顺序读取下一个有效条目（跳过空行/注释，处理 [命名空间] 段落头）
next_entry() {
    local raw line
    while IFS= read -r -u 3 raw || [ -n "$raw" ]; do
        line="$(trim "$raw")"
        if [ -z "$line" ]; then continue; fi
        case "$line" in \#*) continue ;; esac
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_space="$(trim "${BASH_REMATCH[1]}")"
            continue
        fi
        ENTRY="$line"
        return 0
    done
    return 1
}

# ===== 预检查：命名空间与镜像引用字符串是否合法 =====
bad=0
announce=0
current_space=""
exec 3< images.txt
while next_entry; do
    parse_line "$ENTRY"
    if [ -z "$IMAGE" ]; then continue; fi
    space="${SPACE:-$current_space}"
    if [ -z "$space" ]; then
        echo "::error::$ENTRY 没有指定目标命名空间，请用 [命名空间] 段落或 --space=xxx"
        bad=$((bad + 1))
    elif ! [[ "$space" =~ ^[a-z0-9]+([-.]?[a-z0-9]+)*$ ]]; then
        echo "::error::命名空间 '$space' 不合法（只允许小写字母、数字、短划线）"
        bad=$((bad + 1))
    fi
    if ! [[ "$IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
        echo "::error::$ENTRY 含有非法字符（常见原因：全角空格、中文标点、行内多余空格）"
        bad=$((bad + 1))
    fi
    if [ -n "$TAG" ] && ! [[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
        echo "::error::$ENTRY 的 --tag '$TAG' 不合法（只允许字母、数字、下划线、点、短划线，且不能以点或短划线开头）"
        bad=$((bad + 1))
    fi
done
exec 3<&-
if [ "$bad" -gt 0 ]; then
    echo "::error::images.txt 配置有 $bad 处问题，已中止"
    exit 1
fi

# ===== 重名检测（同一目标命名空间内） =====
declare -A duplicate_images
declare -A temp_map
current_space=""
exec 3< images.txt
while next_entry; do
    parse_line "$ENTRY"
    if [ -z "$IMAGE" ]; then continue; fi
    space="${SPACE:-$current_space}"
    split_image "$IMAGE"
    key="${space}/${IMAGE_NAME}"
    up_ns="${NAME_SPACE}_"
    if [ -n "${temp_map[$key]:-}" ]; then
        if [ "${temp_map[$key]}" != "$up_ns" ]; then
            echo "duplicate image name: $key (${temp_map[$key]} vs $up_ns)"
            duplicate_images[$key]="true"
        fi
    else
        temp_map[$key]="$up_ns"
    fi
done
exec 3<&-

# ===== 生成 matrix =====
entries=()
current_space=""
exec 3< images.txt
while next_entry; do
    parse_line "$ENTRY"
    if [ -z "$IMAGE" ]; then continue; fi
    space="${SPACE:-$current_space}"
    split_image "$IMAGE"

    # 目标 tag：--tag 优先，其次镜像自带的 tag，都没有就 latest
    if [ -n "$TAG" ]; then
        IMAGE_NAME_TAG="${IMAGE_NAME}:${TAG}"
    else
        case "$IMAGE_NAME_TAG" in
            *:*) ;;
            *) IMAGE_NAME_TAG="${IMAGE_NAME_TAG}:latest" ;;
        esac
    fi

    if [ -n "$PLATFORM" ]; then
        platform_prefix="${PLATFORM//\//_}_"
    else
        platform_prefix=""
    fi

    name_space_prefix=""
    if [ -n "${duplicate_images[${space}/${IMAGE_NAME}]:-}" ] && [ -n "$NAME_SPACE" ]; then
        name_space_prefix="${NAME_SPACE}_"
    fi

    target="${space}/${platform_prefix}${name_space_prefix}${IMAGE_NAME_TAG}"

    entries+=("$(printf '{"image":"%s","platform":"%s","space":"%s","target":"%s"}' \
        "$IMAGE" "$PLATFORM" "$space" "$target")")
done
exec 3<&-

if [ "${#entries[@]}" -eq 0 ]; then
    echo "::error::images.txt 里没有有效镜像"
    exit 1
fi

matrix="{\"include\":[$(IFS=,; echo "${entries[*]}")]}"

echo "共 ${#entries[@]} 个镜像待搬运："
for e in "${entries[@]}"; do
    printf '  %s\n' "$e"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### 待搬运镜像（${#entries[@]} 个）"
        echo ""
        echo "| 源镜像 | 目标 | 架构 |"
        echo "| --- | --- | --- |"
        for e in "${entries[@]}"; do
            img="$(printf '%s' "$e" | sed -n 's/.*"image":"\([^"]*\)".*/\1/p')"
            tgt="$(printf '%s' "$e" | sed -n 's/.*"target":"\([^"]*\)".*/\1/p')"
            plt="$(printf '%s' "$e" | sed -n 's/.*"platform":"\([^"]*\)".*/\1/p')"
            echo "| \`$img\` | \`$tgt\` | ${plt:--} |"
        done
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "matrix=$matrix"
        echo "count=${#entries[@]}"
    } >> "$GITHUB_OUTPUT"
else
    echo
    echo "$matrix"
fi
