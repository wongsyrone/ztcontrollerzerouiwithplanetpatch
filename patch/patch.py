#!/usr/bin/env python
# -*- coding: UTF-8 -*-

import os
import sys
import json
import time
from datetime import datetime

# Check patch allow variable
if os.environ.get('PATCH_ALLOW', '0') != '1':
    print("PATCH: Nothing to do")
    exit()

# Load data from planets.json
# @pFile, location of planets.json
def loadPlanets(pFile):
    with open(pFile, 'r') as f:
        data = json.load(f)
    f.close()
    return data["planets"]


# Find string in lines
def findString(lines, s):
    i = 0
    s = s.strip()
    for line in lines:
        i = i + 1
        l = line.strip()
        if l[:len(s)] == s:
            return i


# Modify mkworld.cpp of ZeroTierOne
# @mFile, location of mkworld.cpp
# @pFile, location of planets.json
def modifyMKWORLD(mFile, pFile):
    with open(mFile, 'r') as file:
        lines = file.read().splitlines()
    file.close()

    roots = loadPlanets(pFile)

    worldStartLineNum = findString(lines, "// EDIT BELOW HERE")
    worldEndLineNum = findString(lines, "// END WORLD DEFINITION")

    planets = []
    for p in roots:
        planets.append("")
        planets.append("	// {}".format(p["Location"]))
        planets.append("	roots.push_back(World::Root());")
        planets.append(
            "	roots.back().identity = Identity(\"{}\");".format(p["Identity"]))
        for ep in p["Endpoints"]:
            planets.append(
                "	roots.back().stableEndpoints.push_back(InetAddress(\"{}\"));".format(ep))

    ts = int(round(time.time() * 1000))
    fileContent = []
    fileContent.extend(lines[0:worldStartLineNum + 4])
    fileContent.append(
        "	const uint64_t ts = {}ULL; // {}".format(
            ts, datetime.utcfromtimestamp(int(ts/1000)).strftime('%Y-%m-%d %H:%M:%S'))
    )
    fileContent.extend(planets)
    fileContent.extend(lines[worldEndLineNum - 2:])

    with open(mFile, 'w') as file:
        for l in fileContent:
            file.write(l+"\n")
    file.close()


# Build mkworld
# @mFile, location of mkworld.cpp
# @wFile, location of world.c
def buildMKWORLD(mFile, wFile):
    # mkworld.cpp is vendored in this repo (see mkworld/README.md) because
    # upstream deleted attic/world/ in commit 21986038b. It compiles against
    # the ZeroTierOne source tree we just unpacked next to it.
    ztDir = os.path.dirname(os.path.dirname(os.path.abspath(mFile)))  # .../ZeroTierOne
    src = [
        "ECC.cpp", "Salsa20.cpp", "SHA512.cpp", "Identity.cpp",
        "Utils.cpp", "InetAddress.cpp",
    ]
    cpp = [os.path.join(ztDir, "node", f) for f in src]
    cpp.append(os.path.join(ztDir, "osdep", "OSUtils.cpp"))
    cpp.append(mFile)
    cmd = "g++ -I{} -I{}/ext -o mkworld {} -std=c++11 -w".format(
        ztDir, ztDir, " ".join('"%s"' % p for p in cpp))
    rc = os.system(cmd)
    if rc != 0:
        print("FATAL: mkworld compilation failed (%s)" % cmd)
        sys.exit(1)
    rc = os.system("{} > \"{}\"".format(
        os.path.join(os.path.dirname(mFile), "mkworld"),
        os.path.abspath(wFile)))
    if rc != 0:
        print("FATAL: mkworld execution failed")
        sys.exit(1)


# Modify node/Topology.cpp
# @tFile, location of Topology.cpp
# @wFile, location of world.c
def modifyTOPOLOGY(tFile, wFile):
    with open(tFile, 'r') as file:
        lines = file.read().splitlines()
    file.close()

    with open(wFile, 'r') as worldFile:
        world = worldFile.read().splitlines()
    worldFile.close()

    worldStartLineNum = findString(
        lines, "#define ZT_DEFAULT_WORLD_LENGTH ")
    worldEndLineNum = findString(
        lines, "static const unsigned char ZT_DEFAULT_WORLD[ZT_DEFAULT_WORLD_LENGTH] = ")

    fileContent = []
    fileContent.extend(lines[:worldStartLineNum - 1])
    fileContent.extend(world)
    fileContent.extend(lines[worldEndLineNum:])

    with open(tFile, 'w') as file:
        for l in fileContent:
            file.write(l+"\n")
    file.close()


# Patch controller/PostgreSQL.cpp
# @pgFile, location of PostgreSQL.cpp
def patchPOSTGRESQL(pgFile, patchFile):
    os.system(
        "cd {}/.. && patch -p 0 < {}".format(os.path.dirname(pgFile), os.path.abspath(patchFile)))


def main():
    mFile = os.path.abspath("./mkworld/mkworld.cpp")
    tFile = os.path.abspath("./ZeroTierOne/node/Topology.cpp")
    pgFile = os.path.abspath("./ZeroTierOne/nonfree/controller/PostgreSQL.cpp")
    pFile = os.path.abspath("./patch/planets.json")
    patchFile = os.path.abspath("./patch/PostgreSQL.cpp.patch")
    wFile = os.path.abspath("./config/world.c")

    for f in (mFile, tFile, pgFile, pFile):
        if not os.path.exists(f):
            print("FATAL: expected path missing: %s" % f)
            sys.exit(1)

    # Modify mkworld.cpp with planets.json
    modifyMKWORLD(mFile, pFile)
    # Compile mkworld.cpp
    buildMKWORLD(mFile, wFile)
    # Modify node/Topology.cpp with world.c
    modifyTOPOLOGY(tFile, wFile)
    # Patch nonfree/controller/PostgreSQL.cpp
    # patchPOSTGRESQL(pgFile, patchFile)


main()
