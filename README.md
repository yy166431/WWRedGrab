# WWRedGrab

企业微信秒抢红包 dylib（协议直拆 / 巨魔 TrollFools）

## 目标

- `com.tencent.ww` 企业微信 5.0.10+
- iOS 15+ arm64

## 原理（跟安卓拼手速）

不走点开 UI，走官方同一条网络链：

1. `OnAddMessage` 发现红包消息  
2. `tony_onClickHongbaoMessage` → 内部 **SendGrabHongBao**  
3. 截获 `openHongBaoWindow:...openBlock:` → **直接回调 openBlock**  
   - openBlock 内部就是 **SendUnWrapHongBao**（协议拆包）  
   - **不创建开包窗 / 详情页**  
4. 金额：`mSelfRecvAmount` / `didOpenRedEvnSuc` / header amount / RecvInfo 通知

延迟建议 **0ms**。白名单 = 会话名包含则**不抢**。

## 功能

- 协议直拆（无弹窗）
- 悬浮球：开关 / 延迟 / 白名单 / 累计金额 / 记录
- 中文面板

## 构建

GitHub Actions → artifact `WWRedGrab-dylib`  
或 macOS: `make`

## 注入

TrollFools → 企业微信 → 注入 `WWRedGrab.dylib` → 强杀重开

日志：`[WWRedGrab]`
