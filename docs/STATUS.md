# Thimble status

A Bluesky client written in `app/*.tl`, compiled by `tools/tlc.py` to a compressed
VM image run by `runtime/host.c`.

## Sizes (measured, zip -9 of an arm64 device build, ad-hoc signed)

| Stage | VM | Native C |
|---|---|---|
| Trivial app (fixed cost) | 6,549 | 3,901 |
| Login, timeline, thread | 9,823 | 12,997 |
| All features before OAuth | 14,482 | 26,069 |
| Final, including OAuth | 16,555 | 31,432 |

These are estimates of store download size. They exclude a real distribution
signature and provisioning profile, and App Store processing has not been tested.

## Commands

- Build: `zsh tools/build.sh vm|c sim|dev [test]`
- Scripted UI test: `zsh tools/runtest.sh vm tests/core.txt`
- OAuth UI test: `zsh tools/oauthtest.sh`
- Test accounts: `python3 -I tools/bsky.py setup|cleanup`

Run `cleanup` then `setup` between test scripts. Tests assume a clean account.

## Verification

Simulator only. Never run on hardware.

Live against Bluesky (test accounts): sign-in, timeline, photo post with alt text,
reply, like, repost, profile, follow state, block and unblock, search, alerts,
direct messages, full-size image, sign-out, session persistence, OAuth.

Mocked: moderation filtering, report submission (never sent to real moderators),
HLS video feed item. Video playback used Apple's public test stream.

## Not done

- Video upload (stretch goal).
- Release OAuth: needs `docs/client-metadata.template.json` hosted publicly, a
  custom-scheme redirect, and `oauthclient` set. Until then the button is hidden.
- Link tapping inside post text: links are coloured and opened from the More menu.
- Memory: closures and their captures are never freed.
