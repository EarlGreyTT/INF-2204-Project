#!/usr/bin/env python3
# Prints the disassembly of one function with the exact number of times
# each instruction ran (Ir), from a callgrind.out recorded with
# --dump-instr=yes.
#
# usage: callgrind-instructions.py callgrind.out binary function
import os
import re
import subprocess
import sys
from collections import Counter

out, binary, func = sys.argv[1:]
binary = os.path.realpath(binary)

names = {}     # callgrind shortens repeated object paths to "(id)"
ob = None      # object the current cost lines belong to
addr = 0       # last address; most are written relative to it
skip = False   # the cost line after calls= is the callee's total, not ours
ir = Counter()

for l in open(out):
    if m := re.match(r"(c?)ob=(?:\((\d+)\))? ?(.*)", l.rstrip("\n")):
        callee, id, name = m.groups()
        if name:
            names[id] = name
        if not callee:
            ob = name or names[id]
    elif l.startswith("calls="):
        skip = True
    elif l[0] in "0123456789+-*":
        tok = l.split()
        if tok[0] != "*":
            addr = addr + int(tok[0], 0) if tok[0][0] in "+-" else int(tok[0], 0)
        if not skip and ob == binary and len(tok) > 2:
            ir[addr] += int(tok[2])
        skip = False

dis = subprocess.run(
    ["objdump", "-d", "--no-show-raw-insn", "-M", "intel",
     f"--disassemble={func}", binary],
    capture_output=True, text=True, check=True).stdout
insns = re.findall(r"^\s+([0-9a-f]+):\s+(.*)$", dis, re.M)

start = int(insns[0][0], 16)
print(f"{func}: {sum(ir[int(a, 16)] for a, _ in insns):,} Ir")
for a, text in insns:
    a = int(a, 16)
    count = f"{ir[a]:,}" if ir[a] else "."
    print(f"{count:>14}  {func}+{a - start:<#6x} {text}")
