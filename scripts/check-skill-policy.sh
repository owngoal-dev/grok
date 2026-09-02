#!/usr/bin/env bash
#
# Fail if a Grok staging tree, payload, or shipped system config would install
# extra skill trees, omit the desktop-skill ignore/disabled defaults, or add
# those skills via [skills] paths. Used by make check and scripts/package-deb.sh.

set -Eeuo pipefail

usage() {
    echo "usage: $0 --config <managed-config.toml> [--tree <staging-root>] [--payload <payload-dir>]" >&2
    echo "       $0 --self-test" >&2
    exit 64
}

# Desktop platform bundles iOS does not provide. The shipped managed config
# must ignore/disable these names and must not add them via [skills] paths.
desktop_skills() {
    cat <<'EOF'
pptx
pdf
docx
game-animation-frames
game-asset-core
game-character-consistency
game-tilesets
game-ui-icons
resume-claude
resume-cursor
EOF
}

desktop_skill_defaults() {
    local skill bundled
    # Literal ~ as stored in TOML, not $HOME expansion.
    # shellcheck disable=SC2088
    bundled='~/.grok/bundled/skills'
    printf '%s\n' '[skills]' 'ignore = ['
    while IFS= read -r skill; do
        [[ -n "$skill" ]] || continue
        printf '  "%s/%s",\n' "$bundled" "$skill"
    done < <(desktop_skills)
    printf '%s\n' ']' 'disabled = ['
    while IFS= read -r skill; do
        [[ -n "$skill" ]] || continue
        printf '  "%s",\n' "$skill"
    done < <(desktop_skills)
    printf '%s\n' ']'
}

toml_section_key_equals() {
    local file="$1" section="$2" key="$3" expected="$4"
    awk -v section="$section" -v key="$key" -v expected="$expected" '
        /^\[/ { in_section = ($0 == "[" section "]") }
        in_section {
            line = $0
            sub(/[ \t]*#.*$/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == key " = " expected) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}

toml_section_array_has() {
    local file="$1" section="$2" key="$3" needle="$4"
    awk -v section="$section" -v key="$key" -v needle="$needle" '
        /^\[/ { in_section = ($0 == "[" section "]"); in_array = 0 }
        in_section {
            line = $0
            sub(/[ \t]*#.*$/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line ~ "^" key " = \\[") in_array = 1
            else if (line ~ "^[A-Za-z0-9_]+ = ") in_array = 0
            if (in_array) {
                quoted = "\"" needle "\""
                if (index(line, quoted)) found = 1
                if (line ~ /\]$/) in_array = 0
            }
        }
        END { exit found ? 0 : 1 }
    ' "$file"
}

check_config() {
    local file="$1"
    [[ -f "$file" ]] || {
        echo "error: missing system config: $file" >&2
        return 65
    }
    toml_section_key_equals "$file" "compat.claude" "skills" "false" || {
        echo "error: $file must set [compat.claude] skills = false so Claude vendor skill trees are not scanned by default" >&2
        return 65
    }
    toml_section_key_equals "$file" "compat.cursor" "skills" "false" || {
        echo "error: $file must set [compat.cursor] skills = false so Cursor vendor skill trees are not scanned by default" >&2
        return 65
    }

    local skill ignore_path
    while IFS= read -r skill; do
        [[ -n "$skill" ]] || continue
        # Literal ~ as stored in TOML, not $HOME expansion.
        # shellcheck disable=SC2088
        ignore_path='~/.grok/bundled/skills/'"$skill"
        toml_section_array_has "$file" "skills" "ignore" "$ignore_path" || {
            echo "error: $file [skills] ignore must include $ignore_path so a re-extracted desktop bundle stays hidden" >&2
            return 65
        }
        toml_section_array_has "$file" "skills" "disabled" "$skill" || {
            echo "error: $file [skills] disabled must include $skill; iOS does not provide that desktop skill" >&2
            return 65
        }
        if toml_section_array_has "$file" "skills" "paths" "$ignore_path" \
            || toml_section_array_has "$file" "skills" "paths" "$skill"; then
            echo "error: $file must not add desktop skill $skill via [skills] paths; iOS does not provide it" >&2
            return 65
        fi
    done < <(desktop_skills)
}

check_tree() {
    local root="$1"
    [[ -d "$root" ]] || {
        echo "error: missing staging tree: $root" >&2
        return 65
    }
    local matches
    matches="$(find "$root" -name SKILL.md -print)"
    if [[ -n "$matches" ]]; then
        echo "error: extra skill trees (SKILL.md) under $root:" >&2
        printf '%s\n' "$matches" | sed 's/^/       /' >&2
        return 65
    fi
}

check_payload() {
    local payload="$1"
    [[ -d "$payload" ]] || {
        echo "error: missing payload directory: $payload" >&2
        return 65
    }
    if [[ -d "$payload/skills" ]]; then
        echo "error: payload has a skills directory: $payload/skills" >&2
        return 65
    fi
    check_tree "$payload"
}

self_test() {
    local scratch
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/grok-skill-policy.XXXXXX")"
    trap 'rm -rf -- "$scratch"' RETURN

    local ok_config="$scratch/ok.toml"
    {
        cat <<'EOF'
[compat.claude]
skills = false

[compat.cursor]
skills = false

EOF
        desktop_skill_defaults
    } >"$ok_config"
    check_config "$ok_config"

    local bad_config="$scratch/bad.toml"
    {
        printf '%s\n' '[compat.claude]' 'skills = true' '[compat.cursor]' 'skills = false'
        echo
        desktop_skill_defaults
    } >"$bad_config"
    check_config "$bad_config" 2>/dev/null && {
        echo "error: self-test expected a config with Claude skills enabled to fail" >&2
        return 65
    }

    local missing_skills="$scratch/missing-skills.toml"
    cat >"$missing_skills" <<'EOF'
[compat.claude]
skills = false

[compat.cursor]
skills = false
EOF
    check_config "$missing_skills" 2>/dev/null && {
        echo "error: self-test expected a config without desktop-skill ignore/disabled defaults to fail" >&2
        return 65
    }

    local added_skill="$scratch/added-skill.toml"
    {
        cat <<'EOF'
[compat.claude]
skills = false

[compat.cursor]
skills = false

EOF
        desktop_skill_defaults
        printf '%s\n' 'paths = ["~/.grok/bundled/skills/pptx"]'
    } >"$added_skill"
    check_config "$added_skill" 2>/dev/null && {
        echo "error: self-test expected a config that adds a desktop skill via [skills] paths to fail" >&2
        return 65
    }

    local empty="$scratch/empty"
    mkdir -p "$empty"
    check_tree "$empty"
    check_payload "$empty"

    local with_skill="$scratch/with-skill"
    mkdir -p "$with_skill/usr/libexec/grok/sample"
    printf '%s\n' '# extra' >"$with_skill/usr/libexec/grok/sample/SKILL.md"
    check_tree "$with_skill" 2>/dev/null && {
        echo "error: self-test expected SKILL.md in the staging tree to fail" >&2
        return 65
    }

    local with_payload_skills="$scratch/payload"
    mkdir -p "$with_payload_skills/skills"
    check_payload "$with_payload_skills" 2>/dev/null && {
        echo "error: self-test expected a payload skills directory to fail" >&2
        return 65
    }

    echo "skill policy self-test ok"
}

config=""
tree=""
payload=""
run_self_test=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --config)
        [[ "$#" -ge 2 ]] || usage
        config="$2"
        shift 2
        ;;
    --tree)
        [[ "$#" -ge 2 ]] || usage
        tree="$2"
        shift 2
        ;;
    --payload)
        [[ "$#" -ge 2 ]] || usage
        payload="$2"
        shift 2
        ;;
    --self-test)
        run_self_test=1
        shift
        ;;
    *)
        usage
        ;;
    esac
done

if ((run_self_test)); then
    self_test
    [[ -n "$config" ]] && check_config "$config"
    exit 0
fi

[[ -n "$config" ]] || usage
check_config "$config"
[[ -n "$tree" ]] && check_tree "$tree"
[[ -n "$payload" ]] && check_payload "$payload"
