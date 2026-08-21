# WWRedGrab

企业微信 **纯协议静默秒抢** dylib（巨魔 / TrollFools）

## 行为

收到红包 → **直接协议抢**，不弹开包窗、不进详情。

```
OnAddMessage
  → tony_onClickHongbaoMessage   // SendGrab
  → 截获 openHongBaoWindow       // 偷 hbTicket (80 hex)
  → 隐藏窗 onOpenBtnClick:       // SendUnWrap
  → setMSelfRecvAmount           // 记账(分)
```

## 设置悬浮球

仅设置：开关 / 延迟(建议0) / 白名单(会话名包含则不抢) / 累计金额  
**不是红包 UI**。

## 构建

GitHub Actions → artifact `WWRedGrab-dylib`  
或 macOS: `make`

## 注入

TrollFools → 企业微信 → 注入 `WWRedGrab.dylib` → **强杀重开**

日志：`[WWRedGrab]`  
应见：`发现红包` → `SendGrab via tony` → `截获 openHB` → `协议 UnWrap` → `入账`

## 协议说明

见 [PROTOCOL.md](PROTOCOL.md)（真机 Frida 抓包结论）
