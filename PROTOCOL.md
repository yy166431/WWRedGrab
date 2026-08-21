# WeCom Red Packet Protocol (iOS 5.0.10) — captured 2026-08-21

## Environment
- Device: iPhone12 / iOS 14.8.1
- App: com.tencent.ww wework 5.0.10
- Capture: Frida 17.10 ObjC hooks only (NO SendGrab/UnWrap prologue hooks — those freeze/crash)

## Message model (before open)
`WWKMessageRedEnvelopes`:
- hongbaoID: decimal string e.g. `1000040501202608215438551763955`
- hbTicket: **null on message item**
- wishingWording: string
- hongbaoType: **2**
- hongbaoSubType: **4**
- qyhbsubtype: 0

## Runtime chain (manual open, 3 packets captured)
```
openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:
  → openHongBaoWindow:...openBlock:cancelBlock:   (openBlock often NULL)
  → WWRedEnvOpenHongBaoWindow initWithData:toVidList:hbTicket:conv:
  → _updateUIData
  → onOpenBtnClick:                    << UnWrap happens here
  → detail initWithUnWrapResultData:...
  → setMSelfRecvAmount:                << amount in fen (QWORD)
  → didOpenRedEvnSuc:
```

## Critical fields at openHongBaoWindow
ARM64 objc args (self,_cmd,...):
- a2 / arg0: Grab result data pointer (scoped_refptr / C++ result) — Grab already done before window
- a3 / toVidList: NSArray*
- a4 / hbTicket: pointer; `*hbTicket` as C string = **hex ticket ~80 chars (40 bytes)**
  - examples:
    - `054650947b40fc517d2fe01ad3176564273c4e1af2ffe4ad80cdd4cf3d677c77adf001e3f284ffa4`
    - `e576f64ffd1429f68197f95ef2bfbed65f19f226ae9a329c6f8db84e527139422f8360582770c31f`
    - `beafeb675b6684e66055c7f710656e9e1837e6a4140040e75112122259d7d5e4227750546ce97362`
- a5 / vidTicket: **0** in all captures
- a6 / conv: scoped_refptr stack slot
- a7 / msg: scoped_refptr stack slot
- openBlock: **0 (NULL)** in captures — UnWrap is NOT via openBlock; it's `onOpenBtnClick:`

## Amount
- `setMSelfRecvAmount:` fen = `0x1` → **1 fen = ¥0.01** (test packets)
- Unit confirmed: **fen (分)**

## Binary protocol functions (from static dump, unslid base 0x100000000)
```
SendGrabHongBao   file+0xbca7bc   VA 0x100bca7bc
SendUnWrapHongBao file+0xbcad00   VA 0x100bcad00
```
Logs nearby: hongbaoId=, hbticket=, sceneid=
**Do not inline-hook these prologues on device — freezes/crashes WeCom under Frida.**

## Implications for auto-grab dylib
1. On recv message → read hongbaoID/type/subType from `WWKMessageRedEnvelopes`
2. Trigger Grab (same as `tony_onClickHongbaoMessage` internal path) — ticket not available before this
3. When `openHongBaoWindow` fires, steal:
   - grab result data (a2)
   - hbTicket hex string (a4)
   - toVidList / conv / msg
4. **Skip UI**: do not show window; call same work as `onOpenBtnClick:` (UnWrap) with stolen ticket/data
5. Amount from `setMSelfRecvAmount:` or unwrap result
6. openBlock is unreliable (often nil) — don't depend on it for UnWrap

## Safe automation strategy (next implement)
- Hook `openHongBaoWindow:...` → capture ticket+data → `closeHongBaoWindow` / never present UI
- Then invoke UnWrap path:
  - Option A: call `onOpenBtnClick:` on a window created off-screen then destroy (still UI object, but no display)
  - Option B: reverse onOpenBtnClick → SendUnWrap args and call C function with correct ABI once args fully known
- Prefer Option A first for reliability; Option B after one more capture of SendUnWrap args via stack BP (not prologue patch)

## Files
- `frida_objc_log.txt` / `protocol_capture_ok.txt` — raw capture
- `frida_objc_probe.js` — no-click raw probe
- `run_objc_probe.py` — 45s runner
