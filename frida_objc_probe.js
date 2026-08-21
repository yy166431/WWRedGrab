'use strict';

// SAFE probe: never hook click handlers (they freeze WeCom with Frida).
// Only hook post-click paths. onEnter: send raw ptr strings ONLY, no ObjC calls.

function exp(name) {
  if (typeof Module.getGlobalExportByName === 'function') {
    try { return Module.getGlobalExportByName(name); } catch (e) {}
  }
  if (typeof Module.findGlobalExportByName === 'function') {
    try { return Module.findGlobalExportByName(name); } catch (e) {}
  }
  throw new Error('no ' + name);
}

var objc_getClass = new NativeFunction(exp('objc_getClass'), 'pointer', ['pointer']);
var sel_registerName = new NativeFunction(exp('sel_registerName'), 'pointer', ['pointer']);
var class_getInstanceMethod = new NativeFunction(exp('class_getInstanceMethod'), 'pointer', ['pointer', 'pointer']);
var method_getImplementation = new NativeFunction(exp('method_getImplementation'), 'pointer', ['pointer']);

function U(s) { return Memory.allocUtf8String(s); }
function impOf(cn, sn) {
  var c = objc_getClass(U(cn));
  if (c.isNull()) return null;
  var m = class_getInstanceMethod(c, sel_registerName(U(sn)));
  if (m.isNull()) return null;
  return method_getImplementation(m);
}

function hookRaw(cn, sn, tag) {
  var impl = impOf(cn, sn);
  if (!impl) {
    send({ t: 'info', msg: 'skip ' + cn + ' ' + sn });
    return;
  }
  Interceptor.attach(impl, {
    onEnter: function (args) {
      // ZERO objc calls. Only pointer/int dump.
      var o = { t: tag, sel: sn, self: String(args[0]) };
      try { o.a2 = String(args[2]); } catch (e) {}
      try { o.a3 = String(args[3]); } catch (e) {}
      try { o.a4 = String(args[4]); } catch (e) {}
      try { o.a5 = String(args[5]); } catch (e) {}
      try { o.a6 = String(args[6]); } catch (e) {}
      try { o.a7 = String(args[7]); } catch (e) {}
      try { o.a8 = String(args[8]); } catch (e) {}
      try {
        // vidTicket often int
        if (sn.indexOf('vidTicket') >= 0) o.vidTicket = args[5].toInt32();
      } catch (e) {}
      try {
        if (sn.indexOf('setMSelfRecvAmount') >= 0) o.fen = args[2].toString();
      } catch (e) {}
      // try read C string at a4 if looks like pointer (hbTicket)
      try {
        if (sn.indexOf('hbTicket') >= 0 || sn.indexOf('HongBao') >= 0) {
          var p = args[4];
          if (p && !p.isNull()) {
            try { o.a4c = p.readUtf8String(80); } catch (e) {}
            try {
              var b0 = p.readU8();
              var sz = b0 >> 1;
              if ((b0 & 1) === 0 && sz > 0 && sz < 23) o.a4sso = p.add(1).readUtf8String(sz);
            } catch (e) {}
            try {
              var p2 = p.readPointer();
              if (p2 && !p2.isNull()) o.a4p0 = p2.readUtf8String(80);
            } catch (e) {}
          }
        }
      } catch (e) {}
      send(o);
    }
  });
  send({ t: 'info', msg: 'OK ' + cn + ' ' + sn });
}

// NO click hooks
hookRaw('WWRedEnvelopesMgr', 'openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:', 'openWin');
hookRaw('WWRedEnvelopesMgr', 'openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:', 'openWin');
hookRaw('WWRedEnvelopesMgr', 'openHongBaoWindowForQueryResult:toVidList:hbTicket:vidTicket:conv:', 'openWinQ');
hookRaw('WWRedEnvOpenHongBaoWindow', 'initWithData:toVidList:hbTicket:conv:', 'winInit');
hookRaw('WWRedEnvOpenHongBaoWindow', 'initWithQueryResultData:toVidList:hbTicket:conv:', 'winInitQ');
hookRaw('WWRedEnvOpenHongBaoWindow', 'onOpenBtnClick:', 'openBtn');
hookRaw('WWRedEnvOpenHongBaoWindow', '_updateUIData', 'openUI');
hookRaw('WWRedEnvOpenHongBaoWindow', '_updateUIData:', 'openUI');
hookRaw('WWRedEnvelopesMgr', 'didOpenRedEvnSuc:', 'success');
hookRaw('WWRedEnvOpenResultWindow', '_updateUIData:', 'resultUI');
hookRaw('WWRedEnvOpenResultWindow', 'initWithData:toVidList:hbTicket:conv:', 'resultInit');
hookRaw('WWRedEnvDetailViewController', 'setMSelfRecvAmount:', 'selfAmount');
hookRaw('WWRedEnvDetailViewController', 'initWithUnWrapResultData:toVidList:isFromHistory:conv:', 'detailInit');
hookRaw('WWRedEnvDetailViewController', 'initWithGrabResultData:toVidList:isFromHistory:conv:', 'detailInitG');

send({ t: 'info', msg: 'READY no-click raw-only' });
