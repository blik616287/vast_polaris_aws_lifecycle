#!/usr/bin/env python3
# Stream meaningful Palette provisioning events for the two test clusters every
# 60s. Emits: state changes, milestone events, warnings, and real errors (filters
# out the routine "waiting for control plane" CAPI noise). Exits when both Running.
import json, urllib.request, time, re, os

API = "https://palette.isc-spectro-dev.click"
tok = ""
for line in open("instructions.txt", errors="ignore"):
    m = re.search(r"apikey[:\s]+([A-Za-z0-9+/=]{20,})", line, re.I)
    if m:
        tok = m.group(1); break
CLUSTERS = {"fieldeng": "6a407fda6365d1a6dd61ffa0"}

def req(path, method="GET", body=None):
    r = urllib.request.Request(API + path, method=method,
                               headers={"ApiKey": tok, "Content-Type": "application/json"},
                               data=json.dumps(body).encode() if body else None)
    return json.load(urllib.request.urlopen(r, timeout=15))

def states():
    out = {}
    try:
        for c in req("/v1/dashboard/spectroclusters?limit=30", "POST", {}).get("items", []):
            cid = c.get("metadata", {}).get("uid", "")
            for k, u in CLUSTERS.items():
                if cid == u:
                    st = c.get("status", {})
                    out[k] = "%s/%s" % (st.get("state", "?"), st.get("health", {}).get("state", "?"))
    except Exception as e:
        out["_err"] = str(e)[:60]
    return out

NOISE = re.compile(r"Connect failed|Could not connect|cluster_accessor|Connecting to|waiting for|reconcile\.go|kubeco|not.*available yet", re.I)
ERR = re.compile(r"fail|error|unable|insufficient|forbidden|denied|quota|timeout|invalid|exceed|not found|cannot", re.I)

seen = {k: set() for k in CLUSTERS}
laststate = {}
first = True
hb = 0
print("event-monitor armed (60s)", flush=True)
while True:
    st = states()
    for k in CLUSTERS:
        if k in st and st[k] != laststate.get(k):
            print("%s STATE %s: %s" % (time.strftime("%H:%M:%S"), k, st[k]), flush=True)
            laststate[k] = st[k]
    for k, u in CLUSTERS.items():
        try:
            evs = req("/v1/events/components/spectrocluster/%s?limit=25" % u).get("items", [])
        except Exception:
            continue
        emitted = 0
        for e in reversed(evs):
            eid = e.get("metadata", {}).get("uid", "") or (e.get("message", "")[:40] + e.get("metadata", {}).get("creationTimestamp", ""))
            if eid in seen[k]:
                continue
            seen[k].add(eid)
            reason = e.get("reason", ""); msg = (e.get("message", "") or "").strip(); typ = e.get("type", "")
            ts = e.get("metadata", {}).get("creationTimestamp", "")[11:19]
            meaningful = (reason and reason != "Log") or typ == "Warning" or (ERR.search(msg) and not NOISE.search(msg))
            if meaningful and not (first and emitted >= 2):
                print("  %s %s [%s/%s] %s" % (ts, k, typ, reason, msg[:100]), flush=True)
                emitted += 1
    if all("Running" in laststate.get(k, "") for k in CLUSTERS) and len(laststate) >= 2:
        print("BOTH_RUNNING — ready to validate", flush=True); break
    if any("Deleting" in v or "Failed" in v for v in laststate.values()):
        print("ALERT terminal-ish state: %s" % laststate, flush=True)
    hb += 1
    if hb % 5 == 0:
        print("%s heartbeat: %s" % (time.strftime("%H:%M:%S"), laststate), flush=True)
    first = False
    time.sleep(60)
