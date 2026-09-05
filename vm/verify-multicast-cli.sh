#!/bin/bash
# Walk every operational command the PIM/IGMP op yang defines and check two
# separate things, because they fail differently and one masks the other:
#
#   1. the CLI resolves the path      -- "Invalid command" means the op yang is
#                                        wrong or not installed
#   2. FRR accepts the vtysh command  -- "% Unknown command" means the command
#                                        does not exist in FRR 10.3, which is
#                                        the real risk here: these were written
#                                        against the running 10.3 but never all
#                                        exercised
#
# A command that resolves and returns an empty table is a pass: with no traffic
# some of these are legitimately empty.
#
# The paths live under "show protocols pim ...", not "show pim ..." -- the op
# yang augments /show/protocols. Probing the shorter form reports
# "Invalid command: show [pim]", which looks exactly like the module not being
# installed.
set -u

OUT=${OUT:-/home/aikon/danos/.obs/verify-multicast-cli.log}
YANG=${YANG_DIR:-/home/aikon/danos/build-iso/danos-sources/vyatta-protocols-frr/yang}
LIST=$(mktemp)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
OP=/opt/vyatta/bin/vyatta-op-cmd-wrapper

exec > "$OUT" 2>&1

# The command list is derived from the op YANG rather than kept alongside it.
# A checked-in list goes stale the moment a command is added, and the failure
# mode is silence: the walk passes because it never tried the new command.
python3 - "$YANG" > "$LIST" <<'EOF'
import re, sys, pathlib
for src in sorted(pathlib.Path(sys.argv[1]).glob("vyatta-op-protocols-frr-pim*-v1.yang")):
    lines = src.read_text().split("\n")
    stack, base = [], None
    for ln in lines:
        if "opd:augment" in ln:
            base = ["show", "protocols"]
            continue
        if base is None:
            continue
        m = re.match(r"^(\t*)opd:(command|argument) (\S+) \{", ln)
        if m:
            ind = len(m.group(1))
            while stack and stack[-1][0] >= ind:
                stack.pop()
            stack.append((ind, m.group(3), m.group(2)))
            continue
        if "opd:on-enter" in ln:
            path = " ".join(base + [t for _, t, _ in stack])
            kind = "ARG" if any(k == "argument" for _, _, k in stack) else "OK"
            vt = re.search(r"vtysh -c \"([^\"]+)\"", ln)
            print(f"{path}\t{kind}\t{vt.group(1) if vt else ''}")
EOF
sort -u -o "$LIST" "$LIST"
trap 'rm -f "$LIST"' EXIT
S() { docker exec danos-robot timeout 90 sshpass -p vyatta ssh $SSH_OPTS "vyatta@$1" "$2" 2>&1; }

# R2 is the RP and has both PIM interfaces; R3 carries the IGMP membership.
host_for() { case "$1" in *igmp*) echo 192.168.203.157;; *) echo 192.168.203.156;; esac; }

pass=0; badcli=0; badfrr=0
printf '%-46s %-8s %s\n' "Command" "CLI" "FRR"
printf '%s\n' "----------------------------------------------------------------------"

while IFS=$'\t' read -r path kind vt; do
  [ -n "$path" ] || continue
  h=$(host_for "$path")

  if [ "$kind" = ARG ]; then
    # The argument is a group address; use the group the topology actually has.
    cli_path="${path% ipv4-address} 239.1.1.1"
    vt_cmd="${vt/\$5/239.1.1.1}"
  else
    cli_path="$path"
    vt_cmd="$vt"
  fi

  cli_out=$(S "$h" "$OP $cli_path")
  vt_out=$(S "$h" "sudo vtysh -c \"$vt_cmd\"")

  cli_st=OK; frr_st=OK
  case "$cli_out" in *"Invalid command"*|*"Ambiguous"*) cli_st=FAIL; badcli=$((badcli+1));; esac
  case "$vt_out"  in *"Unknown command"*|*"There is no matched command"*) frr_st=FAIL; badfrr=$((badfrr+1));; esac
  [ "$cli_st" = OK ] && [ "$frr_st" = OK ] && pass=$((pass+1))

  printf '%-46s %-8s %s\n' "$cli_path" "$cli_st" "$frr_st"
  if [ "$cli_st" != OK ] || [ "$frr_st" != OK ]; then
    printf '    CLI: %s\n' "$(printf '%s' "$cli_out" | tr -s ' \n' ' ' | cut -c1-140)"
    printf '    FRR: %s\n' "$(printf '%s' "$vt_out"  | tr -s ' \n' ' ' | cut -c1-140)"
  fi
done < "$LIST"

echo
echo "passed $pass, CLI path failures $badcli, FRR command failures $badfrr"
