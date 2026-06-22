#!/usr/bin/env python3
"""
subagentjobs alert — runs on schedule, sends iMessage when new
(data|analytics) + engineer jobs appear since last check.
Matches: title contains (data AND engineer) OR (analytics AND engineer)
"""
import urllib.request, json, os, re, datetime, subprocess

API = "https://subagentjobs.com/api/jobs"
STATE_FILE = os.path.expanduser("~/.subagentjobs_seen.json")
PHONE = "(425) 647-0604"

PATTERN = re.compile(r"(?=.*(?:data|analytics))(?=.*engineer)", re.IGNORECASE)

def fetch_jobs():
    req = urllib.request.Request(API, headers={"User-Agent": "SubagentJobsAlert/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["jobs"]

def load_seen():
    try:
        return set(json.load(open(STATE_FILE)))
    except Exception:
        return set()

def save_seen(ids):
    json.dump(list(ids), open(STATE_FILE, "w"))

def send_imessage(body: str):
    escaped = body.replace('"', '\\"').replace('\n', '\\n')
    script = f'''tell application "Messages"
  set targetService to 1st account whose service type = iMessage
  set targetBuddy to participant "{PHONE}" of targetService
  send "{escaped}" to targetBuddy
end tell'''
    subprocess.run(["osascript", "-e", script], check=True)

def main():
    jobs = fetch_jobs()
    seen = load_seen()
    all_ids, new_matches = set(), []

    for j in jobs:
        jid = f"{j.get('job_post_id','')}:{j.get('company_name','')}"
        all_ids.add(jid)
        if jid not in seen and PATTERN.search(j.get("title", "")):
            new_matches.append(j)

    save_seen(all_ids)

    if not new_matches:
        print(f"[{datetime.datetime.now().isoformat()}] no new matches ({len(jobs)} total jobs checked)")
        return

    lines = [f"New data/analytics engineer job(s) on subagentjobs.com:"]
    for j in new_matches[:12]:
        lines.append(f"- {j['title']} @ {j.get('company_name','?')}")
    if len(new_matches) > 12:
        lines.append(f"(+{len(new_matches)-12} more)")
    lines.append("subagentjobs.com")

    msg = "\n".join(lines)
    print(msg)
    send_imessage(msg)
    print(f"iMessage sent to {PHONE}: {len(new_matches)} new match(es)")

if __name__ == "__main__":
    main()
