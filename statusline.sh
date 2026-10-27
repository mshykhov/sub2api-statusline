#!/usr/bin/env bash
# Claude Code status line with 5h/7d subscription usage behind a Sub2API gateway.
# Claude Code fills `rate_limits` only for claude.ai logins, so behind a gateway the
# limits come from a cached 1-token ping that reads `anthropic-ratelimit-unified-*` headers.
set -euo pipefail

INTERVAL="${SUB2API_STATUSLINE_INTERVAL:-300}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sub2api-statusline"

blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
purple='\033[38;2;167;139;250m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
reset='\033[0m'
sep=" ${dim}|${reset} "

input=$(cat)
field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null || true; }

# Value from the environment, else from the `env` block of settings.json
resolve() {
    local value="${!1:-}"
    if [ -z "$value" ] && [ -f "$SETTINGS" ]; then
        value=$(jq -r --arg k "$1" '.env[$k] // empty' "$SETTINGS" 2>/dev/null || true)
    fi
    printf '%s' "$value"
}

resolve_key() {
    local key helper
    key=$(resolve ANTHROPIC_AUTH_TOKEN)
    if [ -z "$key" ]; then key=$(resolve ANTHROPIC_API_KEY); fi
    if [ -z "$key" ] && [ -f "$SETTINGS" ]; then
        helper=$(jq -r '.apiKeyHelper // empty' "$SETTINGS" 2>/dev/null || true)
        if [ -n "$helper" ]; then key=$(sh -c "$helper" 2>/dev/null | head -1 || true); fi
    fi
    printf '%s' "$key"
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

fmt_epoch() {
    date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null || true
}

fmt_tokens() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1000000) { v = n / 1000000; if (v == int(v)) printf "%dm", v; else printf "%.1fm", v }
        else if (n >= 1000) printf "%.0fk", n / 1000
        else printf "%d", n }'
}

usage_color() {
    if [ "$1" -ge 90 ]; then echo "$red"
    elif [ "$1" -ge 70 ]; then echo "$orange"
    elif [ "$1" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

header() {
    awk -v k="$2" 'tolower($1) == k ":" { gsub("\r", "", $2); print $2; exit }' "$1"
}

# One 1-token request; the gateway answers with the upstream account's rate limit headers
refresh_limits() {
    local base key model headers out u5 r5 u7 r7
    base=$(resolve ANTHROPIC_BASE_URL)
    key=$(resolve_key)
    if [ -z "$base" ] || [ -z "$key" ]; then return 0; fi
    model="${SUB2API_STATUSLINE_MODEL:-$(resolve ANTHROPIC_DEFAULT_HAIKU_MODEL)}"
    model="${model:-claude-haiku-4-5}"
    headers="$CACHE_DIR/headers.txt"
    curl -s -o /dev/null -D "$headers" --max-time 20 "${base%/}/v1/messages" \
        -H "x-api-key: $key" \
        -H "Authorization: Bearer $key" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$(jq -nc --arg m "$model" '{model: $m, max_tokens: 1, messages: [{role: "user", content: "."}]}')" || return 0
    u5=$(header "$headers" anthropic-ratelimit-unified-5h-utilization)
    r5=$(header "$headers" anthropic-ratelimit-unified-5h-reset)
    u7=$(header "$headers" anthropic-ratelimit-unified-7d-utilization)
    r7=$(header "$headers" anthropic-ratelimit-unified-7d-reset)
    rm -f "$headers"
    if [ -z "$u5" ] && [ -z "$u7" ]; then return 0; fi
    out="$CACHE_DIR/limits.json.tmp"
    jq -n --arg u5 "$u5" --arg r5 "$r5" --arg u7 "$u7" --arg r7 "$r7" '
        def window(u; r): if u == "" then null
            else {used_percentage: ((u | tonumber) * 100), resets_at: (if r == "" then null else (r | tonumber) end)} end;
        {five_hour: window($u5; $r5), seven_day: window($u7; $r7)}' > "$out"
    mv "$out" "$CACHE_DIR/limits.json"
}

# Refresh in the background so the status line never waits on the network
maybe_refresh() {
    local lock="$CACHE_DIR/lock" attempt="$CACHE_DIR/attempt" now
    now=$(date +%s)
    if [ $(( now - $(mtime "$attempt") )) -lt "$INTERVAL" ]; then return 0; fi
    if [ -d "$lock" ] && [ $(( now - $(mtime "$lock") )) -gt 60 ]; then rmdir "$lock" 2>/dev/null || true; fi
    if ! mkdir "$lock" 2>/dev/null; then return 0; fi
    touch "$attempt"
    ( refresh_limits || true; rmdir "$lock" 2>/dev/null || true ) </dev/null >/dev/null 2>&1 &
}

render_window() {
    local label="$1" pct_raw="$2" reset_at="$3" time_fmt="$4" pct color text
    if [ -z "$pct_raw" ]; then return 0; fi
    pct=$(awk -v p="$pct_raw" 'BEGIN { printf "%.0f", p }')
    color=$(usage_color "$pct")
    text="${sep}${white}${label}${reset} ${color}${pct}%${reset}"
    if [ -n "$reset_at" ]; then text+=" ${dim}@$(fmt_epoch "$reset_at" "$time_fmt")${reset}"; fi
    printf '%s' "$text"
}

# ===== Session data =====
model=$(field '.model.display_name')
model="${model:-Claude}"
cwd=$(field '.cwd')
version=$(field '.version')

size=$(field '.context_window.context_window_size')
size="${size:-200000}"
if [ "$size" -eq 0 ]; then size=200000; fi
used=$(jq -r '.context_window.current_usage // {} | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)' <<<"$input" 2>/dev/null || echo 0)

effort=$(field '.effort.level')
if [ -z "$effort" ] && [ -f "$SETTINGS" ]; then effort=$(jq -r '.effortLevel // empty' "$SETTINGS" 2>/dev/null || true); fi

# ===== Rate limits: Claude Code first, gateway ping cache second =====
limits=$(field '.rate_limits')
if [ -z "$limits" ] || [ "$limits" = "null" ]; then
    limits=""
    if [ -n "$(resolve ANTHROPIC_BASE_URL)" ]; then
        mkdir -p "$CACHE_DIR"
        maybe_refresh
        if [ -f "$CACHE_DIR/limits.json" ]; then limits=$(cat "$CACHE_DIR/limits.json"); fi
    fi
fi

if [ -z "$limits" ]; then limits='{}'; fi
now=$(date +%s)
window_field() {
    jq -r --arg w "$1" --arg f "$2" --argjson now "$now" \
        '.[$w] | select(. != null and (.resets_at == null or .resets_at > $now)) | .[$f] // empty' <<<"$limits" 2>/dev/null || true
}

# ===== Output =====
out="${blue}${model}${reset}"

if [ -n "$cwd" ]; then
    out+="${sep}${cyan}${cwd##*/}${reset}"
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -n "$branch" ]; then out+="${dim}@${reset}${green}${branch}${reset}"; fi
fi

out+="${sep}${orange}$(fmt_tokens "$used")/$(fmt_tokens "$size")${reset} ${dim}(${reset}${green}$(( used * 100 / size ))%${reset}${dim})${reset}"

if [ -n "$effort" ]; then
    case "$effort" in
        low)    effort_color="$dim" ;;
        medium) effort_color="$orange" ;;
        xhigh)  effort_color="$purple" ;;
        max)    effort_color="$red" ;;
        *)      effort_color="$green" ;;
    esac
    out+="${sep}effort: ${effort_color}${effort}${reset}"
fi

out+=$(render_window 5h "$(window_field five_hour used_percentage)" "$(window_field five_hour resets_at)" "%H:%M")
out+=$(render_window 7d "$(window_field seven_day used_percentage)" "$(window_field seven_day resets_at)" "%a %b %-d, %H:%M")

if [ -n "$version" ]; then out+="${sep}${orange}v${version}${reset}"; fi

printf '%b' "$out"
