import vymgmt, traceback
h = vymgmt.Router("192.168.203.155", "vyatta", password="vyatta", port=22)
try:
    h.login(); print("  login OK")
    h.configure(); print("  configure OK")
    h.set("interfaces dataplane dp0s9 address 65.1.1.2/24"); print("  set OK")
    h.commit(); print("  commit OK")
    h.exit(); h.logout(); print("  VYMGMT_OK")
except Exception as e:
    print("  FAILED:", type(e).__name__, str(e)[:300])
    traceback.print_exc()
