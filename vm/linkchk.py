import paramiko
def run(ip, cmd):
    c=paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(ip,22,"vyatta","vyatta",timeout=20)
    i,o,e=c.exec_command(cmd,timeout=40)
    out=o.read().decode().strip(); c.close(); return out
for n,ip in [("R1","192.168.203.155"),("R2","192.168.203.156"),("R3","192.168.203.157")]:
    print(f"  === {n} {ip} ===")
    print("   ", run(ip,"/opt/vyatta/bin/vyatta-op-cmd-wrapper show interfaces 2>&1 | tail -6").replace("\n","\n    "))
