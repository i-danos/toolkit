#!/usr/bin/env python3
"""Start many router-originated probe flows with different source/destination address pairs.

The kernel hashes equal-cost multipath on source and destination ADDRESS only
(fib_multipath_hash_policy=0), so whether a given flow lands on a dead next hop depends on the address
pair, not on ports. To estimate what share of router-originated traffic a stuck next-hop group
affects, this opens one 5 pps ping per (source, destination) pair, plus TCP echo connections, on R1
and R2. Sources must be addresses that stay up while the link is down (loopbacks, other links): the
failed link's own address is removed by zebra and cannot be a source.

Run hw-link-cycle.py to create the outages, then hw-exposure-analyze.py. Needs hw_ssh.py (as `jump`).
Edit the source/destination lists and the echo target for the topology.
"""
import jump,paramiko,sys,time,re,json
DUR=int(sys.argv[1]) if len(sys.argv)>1 else 1700
R1S=["10.255.0.1","192.168.71.2","192.168.73.2"]+["10.255.1.%d"%i for i in range(1,7)]
R1D=["192.168.75.2","192.168.75.4"]
R2S=["10.255.0.2","192.168.73.3","192.168.75.2"]+["10.255.2.%d"%i for i in range(1,7)]
R2D=["192.168.71.1"]
ECHO_SRV='''import socket,threading
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0",9000)); s.listen(20)
def h(c):
    try:
        while True:
            d=c.recv(64)
            if not d: break
            c.sendall(d)
    except Exception: pass
    c.close()
while True:
    c,_=s.accept(); threading.Thread(target=h,args=(c,),daemon=True).start()
'''
ECHO_CLI='''import socket,time,threading,sys
SRCS=%r
def run(src):
    s=None; stall=None
    while True:
        try:
            if s is None:
                s=socket.socket(); s.bind((src,0)); s.settimeout(3); s.connect(("192.168.75.4",9000)); s.settimeout(1.0)
                print("%%.1f %%s CONNECT"%%(time.time(),src),flush=True)
            s.sendall(b"x"); s.recv(8)
            if stall is not None:
                print("%%.1f %%s RECOVER stall_secs=%%.1f"%%(time.time(),src,time.time()-stall),flush=True); stall=None
            time.sleep(0.2)
        except socket.timeout:
            if stall is None: stall=time.time(); print("%%.1f %%s STALL_START"%%(time.time(),src),flush=True)
        except Exception as e:
            print("%%.1f %%s ERROR %%s"%%(time.time(),src,type(e).__name__),flush=True)
            if stall is None: stall=time.time()
            try: s.close()
            except Exception: pass
            s=None; time.sleep(0.5)
for src in SRCS: threading.Thread(target=run,args=(src,),daemon=True).start()
time.sleep(%d)
'''
def put(r,path,text):
    sf=r.open_sftp(); f=sf.open(path,"w"); f.write(text); f.close(); sf.close()
j1,r1=jump.connect('192.168.71.2'); j2,r2=jump.connect('192.168.73.3')
r4=paramiko.SSHClient(); r4.set_missing_host_key_policy(paramiko.AutoAddPolicy())
r4.connect('192.168.75.4',username='admin',password='admin',timeout=15,look_for_keys=False,allow_agent=False)
put(r1,"/tmp/echo_cli.py",ECHO_CLI%(R1S[:6],DUR+60))
for r in (r1,r2): jump.run(r,"pkill -f '[p]ing -I'; pkill -f '[e]cho_cli.py'; rm -f /tmp/flow_*.txt /tmp/echo_R1.log; true")
n=int(DUR/0.2)
for r,srcs,dsts,tag in ((r1,R1S,R1D,"R1"),(r2,R2S,R2D,"R2")):
    for s in srcs:
        for d in dsts:
            r.exec_command("nohup ping -I %s -D -O -i 0.2 -c %d %s > /tmp/flow_%s_%s_%s.txt 2>&1 &"%(s,n,d,tag,s,d))
r1.exec_command("nohup python3 -u /tmp/echo_cli.py > /tmp/echo_R1.log 2>&1 &")
time.sleep(8)
print("started; flows:",jump.run(r1,"ls /tmp/flow_R1_* | wc -l"),jump.run(r2,"ls /tmp/flow_R2_* | wc -l"))
print("echo:",jump.run(r1,"cat /tmp/echo_R1.log"))
print("sample ping line R1:",jump.run(r1,"tail -2 /tmp/flow_R1_10.255.0.1_192.168.75.4.txt"))
print("sample ping line R2:",jump.run(r2,"tail -2 /tmp/flow_R2_10.255.0.2_192.168.71.1.txt"))
