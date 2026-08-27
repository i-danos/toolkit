import paramiko
for name, ip in [("R1","192.168.203.231"),("R2","192.168.203.232"),("R3","192.168.203.233")]:
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(ip, 22, "vyatta", "vyatta", timeout=20)
        i,o,e = c.exec_command("ls /sys/class/net/ | tr '\\n' ' '; echo; systemctl is-active ssh lighttpd | tr '\\n' ' '", timeout=25)
        print(f"  {name} {ip}: {o.read().decode().strip()}")
        c.close()
    except Exception as ex:
        print(f"  {name} {ip}: FAILED {type(ex).__name__} {ex}")
