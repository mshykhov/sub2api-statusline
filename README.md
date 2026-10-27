# sub2api-statusline

Claude Code status line that shows your Claude subscription usage (5-hour and 7-day windows) when Claude Code runs through a [Sub2API](https://github.com/Wei-Shaw/sub2api) gateway.

```
Opus 5.5 | my-project@main | 92k/1m (9%) | effort: high | 5h 12% @20:00 | 7d 3% @Wed Oct 28, 23:00 | v2.1.311
```

## Why

Claude Code fills the status line `rate_limits` field only for claude.ai Pro/Max logins. Behind a gateway (`ANTHROPIC_BASE_URL` + API key) it stays `null`, even when the gateway forwards the `anthropic-ratelimit-unified-*` headers.

This script gets the limits itself:

1. If Claude Code provides `rate_limits` (direct claude.ai login), it uses them.
2. Otherwise, every 5 minutes it sends one background request with `max_tokens: 1` to your gateway and reads the `anthropic-ratelimit-unified-5h-*` and `-7d-*` response headers. The result is cached in `~/.cache/sub2api-statusline/` and shared by all open sessions.

The status line itself never waits on the network.

## Install

Requirements: `bash`, `jq`, `curl`.

```bash
curl -fsSL https://raw.githubusercontent.com/mshykhov/sub2api-statusline/main/install.sh | bash
```

The installer copies the script to `~/.claude/sub2api-statusline.sh`, sets `statusLine` in `~/.claude/settings.json`, and keeps a timestamped backup of the old settings. It respects `CLAUDE_CONFIG_DIR`.

No extra setup: the script reads the gateway URL and key from the same places Claude Code does:

- `ANTHROPIC_BASE_URL`, from the environment or the `env` block of `settings.json`
- the key from `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, or `apiKeyHelper`

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `SUB2API_STATUSLINE_INTERVAL` | `300` | Seconds between limit refreshes |
| `SUB2API_STATUSLINE_MODEL` | `ANTHROPIC_DEFAULT_HAIKU_MODEL`, else `claude-haiku-4-5` | Model used for the refresh request |

Each refresh costs about 10 input tokens and 1 output token on a Haiku model.

## Gateway requirement

Sub2API removes upstream response headers that are not on its allowlist, and the rate limit headers are not on it by default. The gateway admin must allow them in `config.yaml` and restart Sub2API:

```yaml
response_headers:
  enabled: true
  additional_allowed:
    - anthropic-ratelimit-unified-5h-utilization
    - anthropic-ratelimit-unified-5h-reset
    - anthropic-ratelimit-unified-7d-utilization
    - anthropic-ratelimit-unified-7d-reset
```

Check it with your key:

```bash
curl -s -D - -o /dev/null "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}' \
  | grep -i ratelimit-unified
```

If the gateway pools several upstream accounts, the numbers belong to the account that served the refresh request.

## Uninstall

Restore the backup `~/.claude/settings.json.bak.<timestamp>`, or remove the `statusLine` key from `settings.json`. Then delete `~/.claude/sub2api-statusline.sh` and `~/.cache/sub2api-statusline/`.

## License

MIT
