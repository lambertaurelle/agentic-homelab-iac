#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Deterministic extractor for shared Google Gemini conversations (RPC ujx1Bf)."""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0 Safari/537.36"
)
DEFAULT_BL = "boq_gemini-web-uiserver_20261029.22_p0"


def run_curl(args: list[str]) -> str:
    cmd = ["curl", "-sS", "-A", USER_AGENT] + args
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return res.stdout


def resolve_share_id_and_bl(url: str, cookie_path: str) -> tuple[str, str]:
    eff_url = run_curl([
        "-L", "-c", cookie_path, "-b", cookie_path,
        "-o", "/dev/null", "-w", "%{url_effective}", url
    ]).strip()

    m = re.search(r"/share/([a-zA-Z0-9_-]+)", eff_url)
    if not m:
        raise ValueError(f"Could not extract shareId from effective URL: {eff_url}")
    share_id = m.group(1)

    canonical_url = f"https://gemini.google.com/share/{share_id}"
    html = run_curl(["-L", "-c", cookie_path, "-b", cookie_path, canonical_url])

    bl = DEFAULT_BL
    wiz_m = re.search(r'"cfb2h"\s*:\s*"([^"]+)"', html)
    if wiz_m:
        bl = wiz_m.group(1)

    return share_id, bl


def fetch_rpc_ujx1Bf(share_id: str, bl: str, cookie_path: str, hl: str = "fr") -> list:
    f_req = json.dumps([[["ujx1Bf", json.dumps([None, share_id, [4]]), None, "generic"]]])
    query = urllib.parse.urlencode({
        "rpcids": "ujx1Bf",
        "source-path": f"/share/{share_id}",
        "bl": bl,
        "hl": hl,
        "_reqid": "12345",
        "rt": "c",
    })
    rpc_url = f"https://gemini.google.com/_/BardChatUi/data/batchexecute?{query}"

    raw = run_curl([
        "-L", "--post301", "--post302", "--post303",
        "-b", cookie_path, "-c", cookie_path,
        "-H", "Content-Type: application/x-www-form-urlencoded;charset=UTF-8",
        "-H", "Origin: https://gemini.google.com",
        "-H", f"Referer: https://gemini.google.com/share/{share_id}",
        "--data-urlencode", f"f.req={f_req}",
        rpc_url,
    ])

    for line in raw.splitlines():
        if line.startswith('[["wrb.fr","ujx1Bf"'):
            outer = json.loads(line)
            inner_str = outer[0][2]
            if not inner_str:
                raise RuntimeError(f"Empty RPC payload returned: {line[:300]}")
            return json.loads(inner_str)

    raise RuntimeError(f"wrb.fr ujx1Bf frame not found in response: {raw[:500]}")


def format_markdown(data: list, share_id: str) -> tuple[str, dict]:
    conv_root = data[0] if data and isinstance(data[0], list) else []
    turns = conv_root[1] if len(conv_root) > 1 and isinstance(conv_root[1], list) else []
    meta = conv_root[2] if len(conv_root) > 2 else None
    title = meta[1] if isinstance(meta, list) and len(meta) > 1 and isinstance(meta[1], str) else f"Shared Conversation ({share_id})"

    md_lines = [f"# {title}\n", f"- **Share ID**: `{share_id}`", f"- **Total Turns**: {len(turns)}\n", "---\n"]
    summary_turns = []

    for idx, turn in enumerate(turns, 1):
        try:
            user_prompt = turn[2][0][0] or ""
        except (IndexError, TypeError):
            user_prompt = ""

        try:
            model_resp = turn[3][0][0][1][0] or ""
        except (IndexError, TypeError):
            model_resp = ""

        fallback_note = ""
        if not model_resp and len(turn) > 3 and isinstance(turn[3], list) and len(turn[3]) > 4:
            fallback_note = f"\n> *[Note: Turn {idx} response body is empty or exported to an external artifact/canvas. Raw metadata: `{json.dumps(turn[3][4], ensure_ascii=False)}`]*\n"

        summary_turns.append({
            "turn": idx,
            "user_chars": len(user_prompt),
            "model_chars": len(model_resp),
        })
        md_lines.append(
            f"## Turn {idx}\n\n### User\n\n{user_prompt}\n\n### Gemini\n\n{model_resp}{fallback_note}\n\n---\n"
        )

    return "\n".join(md_lines), {"share_id": share_id, "title": title, "turns": summary_turns}


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract a shared Google Gemini conversation.")
    parser.add_argument("url", help="Shared Gemini URL (share.gemini.google/... or gemini.google.com/share/...)")
    parser.add_argument("--output-md", help="Path to write formatted Markdown transcript")
    parser.add_argument("--output-json", help="Path to write raw parsed JSON payload")
    parser.add_argument("--hl", default="fr", help="Language code for RPC request (default: fr)")
    args = parser.parse_args()

    with tempfile.NamedTemporaryFile(prefix="gemini_cookies_", suffix=".txt", delete=False) as tf:
        cookie_path = tf.name

    try:
        share_id, bl = resolve_share_id_and_bl(args.url, cookie_path)
        print(f"[gemini-share-extractor] Resolved share_id={share_id}, bl={bl}", file=sys.stderr)
        data = fetch_rpc_ujx1Bf(share_id, bl, cookie_path, hl=args.hl)
        md_content, summary = format_markdown(data, share_id)
        print(f"[gemini-share-extractor] Extracted '{summary['title']}' ({len(summary['turns'])} turns)", file=sys.stderr)

        if args.output_json:
            os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
            with open(args.output_json, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)

        if args.output_md:
            os.makedirs(os.path.dirname(os.path.abspath(args.output_md)), exist_ok=True)
            with open(args.output_md, "w", encoding="utf-8") as f:
                f.write(md_content)
            print(json.dumps({**summary, "output_md": args.output_md, "output_json": args.output_json}, ensure_ascii=False))
        else:
            print(md_content)
        return 0
    finally:
        if os.path.exists(cookie_path):
            os.remove(cookie_path)


if __name__ == "__main__":
    sys.exit(main())
