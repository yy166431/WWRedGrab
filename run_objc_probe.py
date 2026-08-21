import frida
import json
import socket
import subprocess
import sys
import time
import paramiko

HOST = "127.0.0.1"
SSH_PORT = 22
FRIDA_PORT = 27042
KEY = r"C:\Users\Administrator\.ssh\id_ed25519"
JS = r"C:\Users\Administrator\Desktop\qiyeVX\WWRedGrab\frida_objc_probe.js"
LOG = r"C:\Users\Administrator\Desktop\qiyeVX\WWRedGrab\frida_objc_log.txt"
WAIT = 45


def port_open(port: int) -> bool:
    s = socket.socket()
    s.settimeout(1)
    try:
        return s.connect_ex((HOST, port)) == 0
    finally:
        s.close()


def ssh_run(cmd: str, timeout: int = 25) -> str:
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        HOST,
        SSH_PORT,
        username="root",
        key_filename=KEY,
        timeout=8,
        allow_agent=False,
        look_for_keys=False,
    )
    _, o, e = c.exec_command(cmd, timeout=timeout)
    out = o.read().decode("utf-8", "replace")
    err = e.read().decode("utf-8", "replace")
    c.close()
    return (out + err).strip()


def ensure_env() -> None:
    if not port_open(SSH_PORT):
        raise SystemExit("SSH 127.0.0.1:22 不通")
    # start frida-server only for this session (not launchctl permanent)
    ssh_run(
        "killall -9 frida-server 2>/dev/null; sleep 0.3; "
        "nohup /usr/sbin/frida-server -l 127.0.0.1:27042 >/tmp/frida.log 2>&1 & "
        "sleep 0.8; ps aux | grep '[f]rida-server'"
    )
    if not port_open(FRIDA_PORT):
        subprocess.Popen(
            [
                "ssh",
                "-i",
                KEY,
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-N",
                "-L",
                f"{FRIDA_PORT}:127.0.0.1:{FRIDA_PORT}",
                f"root@{HOST}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(1.0)
    if not port_open(FRIDA_PORT):
        raise SystemExit("Frida 27042 隧道失败")


def find_wework(device):
    for p in device.enumerate_processes():
        name = p.name or ""
        if "企业微信" in name or "wework" in name.lower():
            return p
    return None


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ensure_env()
    print(f"[*] frida {frida.__version__}  runtime-ObjC only (no C prologue hooks)")

    device = frida.get_device_manager().add_remote_device(f"{HOST}:{FRIDA_PORT}")
    proc = find_wework(device)
    if not proc:
        print("[*] 拉起企业微信...")
        ssh_run("uiopen -b com.tencent.ww")
        time.sleep(2.5)
        proc = find_wework(device)
    if not proc:
        raise SystemExit("没有企业微信进程，先手动打开")

    print(f"[*] attach {proc.pid} {proc.name}")
    open(LOG, "w", encoding="utf-8").write("")
    session = device.attach(proc.pid)
    js = open(JS, "r", encoding="utf-8").read()
    hits = 0

    def on_msg(msg, data):
        nonlocal hits
        if msg["type"] == "send":
            payload = msg["payload"]
            line = json.dumps(payload, ensure_ascii=False, default=str)
            t = payload.get("t") if isinstance(payload, dict) else ""
            if t == "info":
                print("[info]", payload.get("msg"), flush=True)
            elif t in ("click", "openWin", "openBtn", "openUI", "success", "resultUI", "selfAmount"):
                hits += 1
                print(f"\n>>> {t.upper()}", flush=True)
                print(line, flush=True)
            else:
                print(line, flush=True)
        elif msg["type"] == "error":
            line = "ERROR " + json.dumps(msg, ensure_ascii=False)
            print(line, flush=True)
        else:
            line = str(msg)
            print(line, flush=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    script = session.create_script(js)
    script.on("message", on_msg)
    script.load()

    print("=" * 48)
    print("ObjC 探针已挂好（不碰 SendGrab/UnWrap 入口）")
    print("现在立刻：")
    print("  1) 小号发红包")
    print("  2) 主号点开并拆开")
    print(f"窗口 {WAIT} 秒")
    print("=" * 48)

    t0 = time.time()
    while time.time() - t0 < WAIT:
        time.sleep(0.25)

    print("=" * 48)
    print(f"结束 hits={hits}")
    print(f"日志: {LOG}")
    try:
        session.detach()
    except Exception:
        pass
    # stop frida-server after capture to avoid leftover crash risk
    try:
        ssh_run("killall -9 frida-server 2>/dev/null; echo stopped")
    except Exception:
        pass


if __name__ == "__main__":
    main()
