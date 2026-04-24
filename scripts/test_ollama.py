#!/usr/bin/env python3
"""Test Ollama API directly."""
import urllib.request, json, sys, time

def test(host="http://127.0.0.1:11434"):
    # Test 1: health
    try:
        r = urllib.request.urlopen(f"{host}/", timeout=5)
        print(f"[OK] Ollama is up ({r.status})")
    except Exception as e:
        print(f"[FAIL] Ollama not reachable: {e}")
        sys.exit(1)

    # Test 2: generate
    payload = json.dumps({
        "model": "qwen2.5:1.5b",
        "prompt": "Say just the word: hello",
        "stream": False,
        "options": {"num_predict": 5}
    }).encode()
    req = urllib.request.Request(f"{host}/api/generate", data=payload,
                                 headers={"Content-Type": "application/json"})
    print("Sending generate request (may take 30s+ on CPU)...")
    t0 = time.time()
    try:
        r = urllib.request.urlopen(req, timeout=120)
        resp = json.loads(r.read())
        elapsed = time.time() - t0
        print(f"[OK] Response in {elapsed:.1f}s: {resp.get('response','')[:100]!r}")
    except Exception as e:
        print(f"[FAIL] Generate failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    test()
