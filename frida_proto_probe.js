'use strict';

function pstr(p) {
  if (!p || p.isNull()) return 'NULL';
  var out = [p.toString()];
  try {
    if (typeof ObjC !== 'undefined' && ObjC.available) {
      var o = new ObjC.Object(p);
      var cn = o.$className;
      if (cn) {
        out.push('cls=' + cn);
        try {
          if (cn.indexOf('String') >= 0) out.push('ns="' + o.toString() + '"');
        } catch (e) {}
      }
    }
  } catch (e) {}
  try {
    var c = p.readUtf8String(160);
    if (c && c.length > 0) out.push('c="' + c.replace(/\n/g, '\\n').slice(0, 120) + '"');
  } catch (e) {}
  try {
    var b0 = p.readU8();
    var shortSize = b0 >> 1;
    if ((b0 & 1) === 0 && shortSize > 0 && shortSize < 23) {
      var s = p.add(1).readUtf8String(shortSize);
      if (s) out.push('sso="' + s + '"');
    }
  } catch (e) {}
  try {
    for (var oi = 0; oi < 3; oi++) {
      var off = [0, 8, 16][oi];
      var dp = p.add(off).readPointer();
      if (dp.isNull()) continue;
      try {
        var s2 = dp.readUtf8String(160);
        if (s2 && s2.length >= 4 && /^[\x20-\x7e]+$/.test(s2)) {
          out.push('p' + off + '="' + s2.slice(0, 120) + '"');
          break;
        }
      } catch (e) {}
      try {
        if (typeof ObjC !== 'undefined' && ObjC.available) {
          var o2 = new ObjC.Object(dp);
          if (o2.$className && o2.$className.indexOf('String') >= 0)
            out.push('p' + off + 'ns="' + o2.toString() + '"');
        }
      } catch (e) {}
    }
  } catch (e) {}
  try {
    var bytes = new Uint8Array(p.readByteArray(24));
    var hex = '';
    for (var i = 0; i < bytes.length; i++) hex += ('0' + bytes[i].toString(16)).slice(-2);
    out.push('hex24=' + hex);
  } catch (e) {}
  return out.join(' | ');
}

function findMod() {
  var mods = Process.enumerateModules();
  for (var i = 0; i < mods.length; i++) {
    if (mods[i].name === 'wework' || (mods[i].path && mods[i].path.indexOf('wework.app/wework') >= 0))
      return mods[i];
  }
  return mods[0];
}

function head(addr) {
  try {
    var b = new Uint8Array(addr.readByteArray(8));
    var h = '';
    for (var i = 0; i < b.length; i++) h += ('0' + b[i].toString(16)).slice(-2) + ' ';
    return h.trim();
  } catch (e) {
    return 'unreadable';
  }
}

function bt(ctx) {
  try {
    return Thread.backtrace(ctx, Backtracer.FUZZY).slice(0, 8).map(DebugSymbol.fromAddress).map(String);
  } catch (e) {
    return [];
  }
}

var mod = findMod();
send({ t: 'info', msg: 'mod ' + mod.name + ' base=' + mod.base + ' path=' + mod.path });

var grab = mod.base.add(0xbca7bc);
var unwrap = mod.base.add(0xbcad00);
send({ t: 'info', msg: 'Grab@' + grab + ' head=' + head(grab) });
send({ t: 'info', msg: 'UnWrap@' + unwrap + ' head=' + head(unwrap) });

var g = 0, u = 0;

Interceptor.attach(grab, {
  onEnter: function (args) {
    g++;
    send({
      t: 'grab', n: g, thiz: String(args[0]), lr: String(this.returnAddress),
      x1: pstr(args[1]), x2: pstr(args[2]), x3: pstr(args[3]),
      x4: pstr(args[4]), x5: pstr(args[5]), x6: pstr(args[6]),
      bt: bt(this.context)
    });
  },
  onLeave: function (retval) {
    send({ t: 'grab_ret', n: g, ret: String(retval) });
  }
});

Interceptor.attach(unwrap, {
  onEnter: function (args) {
    u++;
    send({
      t: 'unwrap', n: u, thiz: String(args[0]), lr: String(this.returnAddress),
      x1: pstr(args[1]), x2: pstr(args[2]), x3: pstr(args[3]),
      x4: pstr(args[4]), x5: pstr(args[5]), x6: pstr(args[6]), x7: pstr(args[7]),
      bt: bt(this.context)
    });
  },
  onLeave: function (retval) {
    send({ t: 'unwrap_ret', n: u, ret: String(retval) });
  }
});

function hookObjC() {
  if (typeof ObjC === 'undefined' || !ObjC.available) {
    send({ t: 'info', msg: 'ObjC not ready, retry' });
    return false;
  }
  function hobj(clsName, sel) {
    var c = ObjC.classes[clsName];
    if (!c || !c[sel]) {
      send({ t: 'info', msg: 'missing ' + clsName + ' ' + sel });
      return;
    }
    Interceptor.attach(c[sel].implementation, {
      onEnter: function (args) {
        var info = { t: 'objc', cls: clsName, sel: sel };
        try {
          if (sel.indexOf('tony_onClick') >= 0 || sel.indexOf('onClickHongbao') >= 0) {
            var self = new ObjC.Object(args[0]);
            if (self.respondsToSelector_('message')) {
              var msg = self.message();
              if (msg && msg.respondsToSelector_('messageItem')) {
                var it = msg.messageItem();
                if (it) {
                  info.itemCls = it.$className;
                  try { if (it.respondsToSelector_('hongbaoID')) info.hid = String(it.hongbaoID()); } catch (e) {}
                  try { if (it.respondsToSelector_('hbTicket')) info.ticket = String(it.hbTicket()); } catch (e) {}
                  try { if (it.respondsToSelector_('wishingWording')) info.wish = String(it.wishingWording()); } catch (e) {}
                  try { if (it.respondsToSelector_('hongbaoType')) info.type = String(it.hongbaoType()); } catch (e) {}
                  try { if (it.respondsToSelector_('hongbaoSubType')) info.subType = String(it.hongbaoSubType()); } catch (e) {}
                }
              }
            }
          }
          if (sel.indexOf('didOpen') >= 0) {
            try {
              var a = new ObjC.Object(args[2]);
              info.arg2 = String(a) + '/' + a.$className;
            } catch (e) {}
          }
          if (sel.indexOf('openHongBaoWindow') >= 0) {
            try { info.toVidList = String(new ObjC.Object(args[3])); } catch (e) {}
            try { info.hbTicketArg = pstr(args[4]); } catch (e) {}
          }
        } catch (e) {
          info.err = String(e);
        }
        send(info);
      }
    });
    send({ t: 'info', msg: 'hooked ' + clsName + ' ' + sel });
  }
  hobj('WWKConversationRedEnvelopesBubbleView', '- tony_onClickHongbaoMessage');
  hobj('WWKConversationRedEnvelopesBubbleView', '- onClickHongbaoMessage');
  hobj('WWRedEnvelopesMgr', '- openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:');
  hobj('WWRedEnvelopesMgr', '- openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:');
  hobj('WWRedEnvelopesMgr', '- didOpenRedEvnSuc:');
  hobj('WWRedEnvOpenHongBaoWindow', '- onOpenBtnClick:');
  return true;
}

// C hooks already on; ObjC may need a tick
if (!hookObjC()) {
  var n = 0;
  var t = setInterval(function () {
    n++;
    if (hookObjC() || n >= 20) clearInterval(t);
  }, 200);
}

send({ t: 'info', msg: 'READY' });
