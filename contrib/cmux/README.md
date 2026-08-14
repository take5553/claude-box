# cmux notification bridge (opt-in)

[cmux](https://github.com/manaflow-ai/cmux) is a terminal multiplexer that can
surface "waiting for input" / "finished" notifications from the tools it wraps.
When you run `claude-box` from inside a cmux pane, the in-box Claude Code is not
visible to cmux — the wrapper, the notification socket, and even the terminal
bell all stop at the container boundary. This bridge reconnects the two.

It is **off by default** and lives in `contrib/` because cmux is one editor among
many; most claude-box users do not need it. Nothing here is on the critical path
of the sandbox.

## How it works

`claude-box` exposes a generic notification-bridge contract:

- If `CLAUDE_BOX_NOTIFY_BRIDGE` points to an executable, `claude-box` runs it on
  the host, reads the TCP port it prints on its **first stdout line**, and keeps
  it running for the container's lifetime.
- That port is passed into the container as `CLAUDE_BOX_BRIDGE_PORT`, together
  with a `host.docker.internal` mapping so the container can reach the host.
- In-box Claude Code hooks (`contrib/cmux/hooks.json`, injected via `--settings`)
  POST their JSON to the bridge through `claude-box-notify-forward`.
- If the bridge prints nothing and exits, `claude-box` launches the container
  without any bridge.

`notify-bridge` is one implementation of that contract: it relays the hook events
to cmux's own entry point (`cmux hooks ...`). It only activates when it detects a
cmux pane (`CMUX_SURFACE_ID` + a live `CMUX_SOCKET_PATH` socket); otherwise it
declines by printing nothing.

The container-side pieces (`hook-forward`, `hooks.json`) are baked into the image
at build time, so enabling the bridge adds **no runtime egress** beyond the
loopback POST to the host bridge port, which the firewall allows per-port.

## Enabling it

On the host, point the contract at this bridge (e.g. in your shell profile):

```sh
export CLAUDE_BOX_NOTIFY_BRIDGE="$PWD/contrib/cmux/notify-bridge"
```

Then launch `claude-box` from inside a cmux pane as usual. Outside a cmux pane the
bridge declines and `claude-box` behaves exactly as if it were unset.

## Files

| File | Role |
|---|---|
| `notify-bridge` | Host-side bridge: relays in-box hook events to `cmux hooks`. Prints its port, then serves. |
| `hook-forward` | Container-side: POSTs a hook's stdin to the host bridge. Baked in as `/usr/local/bin/claude-box-notify-forward`. |
| `hooks.json` | Claude Code hook settings mapping each event to a `hook-forward` call. Baked in as `/etc/claude-box/notify-hooks.json`. |
