import json, subprocess
from src.inference.config import InferenceConfig
from src.inference.engine import DecisionEngine

LEADS_ORDER = ["Anthropic", "Honeycomb", "Grafter(real)", "Grafter(bogus)", "NoEvidence"]

NO_EVIDENCE = (
    "> **Could not read the site.** No usable content was returned for "
    "`https://example-empty.com`. No evidence gathered.\n\n**Evidence summary**\n"
    "- Sector: No evidence — site not readable.\n- Size: No evidence — site not readable.\n"
    "- Geography: No evidence — site not readable.\n- Revenue-headcount trap: No evidence — site not readable.\n"
    "- Decision readiness: No evidence — site not readable.\n- Decision-maker access: No evidence — site not readable."
)

QUESTIONS = {
    "q0": {
        "type": "choice",
        "instructions": (
            "Decide whether this lead fits Mission Ctrl's ICP. We serve founder-led "
            "consultancies, professional-services, and agency SMEs (~£2-10M revenue, "
            "10-50 staff) based in the UK, UAE/Dubai, or the wider GCC that show a "
            "revenue-headcount trap. Choose Win to pursue, Lose to pass."
        ),
        "criteria": {
            "Win": "A founder-led consultancy / professional-services / agency SME in the UK, UAE, or GCC worth pursuing.",
            "Lose": "Not a services SME, wrong region, an enterprise or product company, or no usable evidence of fit.",
        },
    }
}

def company(r):
    r = (r or "").lower()
    # order matters: "thgrafter" (bogus typo) before the generic "grafter" (real).
    for k, n in [("anthropic", "Anthropic"), ("honeycomb", "Honeycomb"),
                 ("thgrafter", "Grafter(bogus)"), ("grafter", "Grafter(real)")]:
        if k in r:
            return n
    return "?"

def leads():
    out = subprocess.run(
        ["spacetime", "sql", "--format", "json", "--server", "http://127.0.0.1:3000",
         "vfview", "SELECT research FROM lead"], capture_output=True, text=True).stdout
    d = json.loads(out)[0]
    seen = {}
    for row in d["rows"]:
        v = row[0]
        rep = v[1] if isinstance(v, list) and v and v[0] == 0 else None
        c = company(rep)
        if rep and c not in seen:
            seen[c] = rep
    return seen

def main():
    config = InferenceConfig.load("configs/inference/cpu.json")
    print("loading Intern-Decision-4B on CPU (float32)...", flush=True)
    engine = DecisionEngine.from_config(config)
    data = leads()
    data["NoEvidence"] = NO_EVIDENCE
    print(f"\n{'lead':16} {'chosen':6} {'Win':>6} {'Lose':>6} {'conf':>6}")
    print("-" * 46)
    for name in LEADS_ORDER:
        rep = data.get(name)
        if not rep:
            print(f"{name:16} (no research row)")
            continue
        res = engine.predict({"state": {"body": rep}, "questions": QUESTIONS})
        a = res["answers"]["q0"]
        p = a["probabilities"]
        print(f"{name:16} {a.get('choice',''):6} {p.get('Win',0):6.3f} {p.get('Lose',0):6.3f} {a.get('confidence',0):6.3f}", flush=True)

if __name__ == "__main__":
    main()
