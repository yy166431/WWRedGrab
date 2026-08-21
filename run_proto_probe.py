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
JS = r"C:\Users\Administrator\Desktop\qiyeVX\WWRedGrab\frida_proto_probe.js"
LOG = r"C:\Users\Administrator\Desktop\qiyeVX\WWRedGrab\frida_proto_log.txt"
WAIT = 45


def port_open(port: int) -> bool:
    s = socket.socket()
    s.settimeout(1)
    try:
        return s.connect_ex((HOST, port)) == 0
    finally:
        s.close()


def ssh_run(cmd: str, timeout: int = 20) -> str:
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
        raise SystemExit("SSH 127.0.0.1:22 不通，先开 pymobiledevice3 隧道")
    # frida-server
    ssh_run(
        "killall frida-server 2>/dev/null; "
        "nohup /usr/sbin/frida-server -l 127.0.0.1:27042 >/tmp/frida.log 2>&1 & "
        "sleep 0.8; ps aux | grep frida-server | grep -v grep"
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
        raise SystemExit("Frida 隧道 27042 失败")


def find_wework(device):
    for p in device.enumerate_processes():
        name = p.name or ""
        if "企业微信" in name or "wework" in name.lower():
            return p
    return None


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ensure_env()
    print(f"[*] frida {frida.__version__}")

    device = frida.get_device_manager().add_remote_device(f"{HOST}:{FRIDA_PORT}")
    proc = find_wework(device)
    if not proc:
        print("[*] 企业微信没开，正在拉起...")
        ssh_run("uiopen -b com.tencent.ww")
        time.sleep(2.5)
        proc = find_wework(device)
    if not proc:
        raise SystemExit("找不到企业微信进程，先手动打开")

    print(f"[*] attach {proc.pid} {proc.name}")
    open(LOG, "w", encoding="utf-8").write("")
    session = device.attach(proc.pid)
    js = open(JS, "r", encoding="utf-8").read()
    hits = {"grab": 0, "unwrap": 0, "objc": 0}

    def on_msg(msg, data):
        if msg["type"] == "send":
            payload = msg["payload"]
            line = json.dumps(payload, ensure_ascii=False, default=str)
            t = payload.get("t") if isinstance(payload, dict) else None
            if t == "grab":
                hits["grab"] += 1
                print("\n>>> GRAB", flush=True)
            elif t == "unwrap":
                hits["unwrap"] += 1
                print("\n>>> UNWRAP", flush=True)
            elif t == "objc":
                hits["objc"] += 1
                print("\n>>> OBJC", payload.get("sel"), flush=True)
            elif t == "info":
                print("[info]", payload.get("msg"), flush=True)
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

    print("=" * 50)
    print("探针已挂好，只读抓协议，不改任何返回值")
    print("现在请：")
    print("  1) 用小号发一个红包到能看见的群/好友")
    print("  2) 主号点开红包并拆开")
    print(f"等 {WAIT} 秒...")
    print("=" * 50)

    t0 = time.time()
    while time.time() - t0 < WAIT:
        time.sleep(0.3)

    print("=" * 50)
    print(f"结束 grab={hits['grab']} unwrap={hits['unwrap']} objc={hits['objc']}")
    print(f"日志: {LOG}")
    try:
        session.detach()
    except Exception:
        pass


if __name__ == "__main__":
    main()
