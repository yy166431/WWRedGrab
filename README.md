# WWRedGrab

企业微信 **协议层** 秒抢红包 dylib（巨魔 / TrollFools）

## 目标

- `com.tencent.ww` 5.0.10（build 229043）实测 dump
- iOS 15+ arm64

## 和 UI 版的区别

| | UI 点开 | 本版 |
|--|--|--|
| 路径 | 气泡 → 开包窗 → 点开 | **SendGrabHongBao + SendUnWrapHongBao** |
| 弹窗 | 有 | **无** |
| 函数 | ObjC | 二进制 `redenvelopes_protocol_backend.cpp` |

### 协议偏移（unslid，基址 `0x100000000`）

```
SendGrabHongBao   @ 0x100bca7bc   file+0xbca7bc
SendUnWrapHongBao @ 0x100bcad00   file+0xbcad00
```

启动后 inline hook 这两个函数，偷 `protocol this`。  
之后新红包：**直接调 orig Grab → UnWrap**，不创建任何红包 UI。

首次若 `this` 未捕获，会短暂走 `tony_onClick` 组装参数（仍拦截开窗），一旦系统自己发过 Grab，后续全协议。

## 面板

- 自动抢 / 延迟（建议 **0**）
- 白名单 = 会话名包含则**不抢**
- 累计金额 / 记录
- 协议状态：绿=`this` 已就绪

悬浮球：红=未捕获 this，**绿+P**=协议直调就绪

## 构建 / 注入

Actions → `WWRedGrab-dylib`  
TrollFools → 企业微信 → 注入 → **强杀重开**

日志：`[WWRedGrab]`  
关键：`捕获 protocol this` / `协议直调 SendGrab` / `协议直调 SendUnWrap` / `入账`

## 升级

换版本后重新 dump 上述两个偏移再改 `kOff_SendGrab` / `kOff_SendUnWrap`。
