#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Take a physical link down and up on a schedule, with exact timestamps, from the router itself.

Replaces pulling a cable by hand, which is slow and, worse, unrepeatable: this runs N cycles of
`ip link set <if> down`, hold, `ip link set <if> up`, hold, and logs the router's own epoch time at
each action to ./ctrl.log (analysis maps those onto the probe logs).

What it is and is not: the data plane brings the port administratively down, so the NIC's link
really drops and the PEER router sees a genuine link loss (same journal lines, NO-CARRIER). The
router running this sees an admin-down instead, which also takes its kernel interface down and makes
the kernel mark next hops on it dead. So results on the PEER side match a cable pull; results on
this router's own side do not. See DEFECTS.md, "Real hardware: ... exposure".

Usage: hw-link-cycle.py CYCLES DOWN_SECONDS UP_SECONDS START_DELAY_SECONDS
"""
import time
import sys

import hw_ssh as jump
CYCLES=int(sys.argv[1]); DOWN=int(sys.argv[2]); UP=int(sys.argv[3]); DELAY=int(sys.argv[4])
j1,r1=jump.connect('192.168.71.2'); LOG=open("ctrl.log","w",buffering=1)
def act(cmd,label):
    t=jump.run(r1,"date +%s.%N").strip(); jump.sudo(r1,cmd); LOG.write("%s %s r1_epoch=%s\n"%(time.strftime("%H:%M:%S"),label,t))
time.sleep(DELAY)
for k in range(1,CYCLES+1):
    act("ip link set dp0p2s0 down","DOWN cycle %d"%k); time.sleep(DOWN)
    act("ip link set dp0p2s0 up","UP cycle %d"%k); time.sleep(UP)
LOG.write("DONE\n")
