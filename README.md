# WWRedGrab

企业微信 (WeCom) 秒抢红包 dylib — 巨魔 / TrollFools 注入

## Target

- App: 企业微信 `com.tencent.ww`
- Tested binary: 5.0.10 (build 229043)
- iOS 15+
- arm64

## Features

- Auto grab red packets on receive / in-chat bubble
- Floating ball: drag + tap open panel
- Master switch
- Delay 0~3000ms
- Whitelist (conversation name contains → **skip**)
- Total amount + grab count + history
- Reset stats

## Build

GitHub Actions (macos + Xcode):

```
push main → artifact WWRedGrab-dylib
```

Local (macOS):

```bash
make
```

## Install (TrollStore / TrollFools)

1. Actions → latest run → download `WWRedGrab-dylib`
2. TrollFools → 企业微信 → inject `WWRedGrab.dylib`
3. 强杀企业微信重开，等悬浮球出现

## Hook map (5.0.10)

| Class | Selector | Role |
|-------|----------|------|
| `WWKConversationWrapper` | `OnAddMessage:end:inConversation:` | new msg push |
| `WWKMessageListController` | same | list path |
| `WWKConversationRedEnvelopesBubbleView` | `updateData` / `tony_onClickHongbaoMessage` | in-chat + click |
| `WWRedEnvOpenHongBaoWindow` | `_updateUIData` / `onOpenBtnClick:` | auto open |
| `WWRedEnvOpenResultWindow` | `_updateUIData:` | amount |
| `WWRedEnvelopesMgr` | `didOpenRedEvnSuc:` / `openHongBaoWindow:...` | success + window |
| `WWKMessage` | `p_parseHongBaoMessage:` | parse path |

## Notes

- Whitelist = **do not grab** those conversations
- Amount unit follows client `mTotalAmount` (fen)
- If WeCom upgrades breaks hooks, re-dump ObjC and patch selectors
- Logs: `NSLog` tag `[WWRedGrab]`

## Layout

```
WWRedGrab/
├── WWRedGrab.m
├── Makefile
├── .github/workflows/build.yml
└── README.md
```
