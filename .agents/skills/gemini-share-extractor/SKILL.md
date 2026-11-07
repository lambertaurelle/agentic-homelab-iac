---
name: gemini-share-extractor
description: Extracts the full conversation transcript (all user prompts, Gemini responses, and titles) from shared Google Gemini links (https://share.gemini.google/... or https://gemini.google.com/share/...). Use when the user shares a Gemini conversation URL and asks to read, summarize, analyze, or build an implementation plan from its contents.
---

# Gemini Shared Conversation Extractor

## Overview
Shared Google Gemini links (`share.gemini.google/<id>` or `gemini.google.com/share/<id>`) do not embed conversation text in their static HTML. Instead, the web client hydrates the conversation via an internal `batchexecute` RPC (`ujx1Bf` / `/BardFrontendService.GetSharedConversation`) that requires session cookies and `POST`-preserving redirects.

This skill provides a deterministic, single-step extraction script and fallback protocol so you never waste turns debugging empty HTML bodies, `302` redirect loops, or `405` errors.

## When to Use
Use this skill whenever the user provides a URL matching:
- `https://share.gemini.google/<shortId>`
- `https://gemini.google.com/share/<shareId>`
- `https://g.co/gemini/share/<shareId>`

Do **not** use for:
- Local Antigravity conversation transcripts (`conversation://<uuid>`), which are read directly from `<appDataDir>/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`.
- Google Docs links (`docs.google.com/document/d/<id>`).

## Extraction Workflow

### 1. Run the Bundled Extractor Script (Default Path)
Execute `scripts/fetch_gemini_share.py` (located relative to this skill directory) passing the shared URL and an output path in your current conversation's `scratch/` directory:

```bash
python3 scripts/fetch_gemini_share.py \
  "<shared_url>" \
  --output-md "<artifact_dir>/scratch/gemini_conversation.md" \
  --output-json "<artifact_dir>/scratch/gemini_conversation.json"
```

### 2. Inspect the Extracted Transcript
Read the generated Markdown file (`<artifact_dir>/scratch/gemini_conversation.md`) using `read_file` to review all turns in full detail.

### 3. Manual Fallback (If Script Unavailable)
If executing manually via `curl`, you **must** follow these exact invariants:
1. Fetch `https://gemini.google.com/share/<shareId>` (strip `?social_preview=true`) with `-c /tmp/gemini_cookies.txt -b /tmp/gemini_cookies.txt` and extract `cfb2h` from `window.WIZ_global_data`.
2. Call `batchexecute` using `curl -sL --post301 --post302 --post303` (mandatory to prevent `POST` -> `GET` downgrade on `302` redirects):
   ```bash
   curl -sL --post301 --post302 --post303 \
     -b /tmp/gemini_cookies.txt -c /tmp/gemini_cookies.txt \
     -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36" \
     -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
     -H "Origin: https://gemini.google.com" \
     -H "Referer: https://gemini.google.com/share/<shareId>" \
     --data-urlencode 'f.req=[[["ujx1Bf","[null,\"<shareId>\",[4]]",null,"generic"]]]' \
     "https://gemini.google.com/_/BardChatUi/data/batchexecute?rpcids=ujx1Bf&source-path=%2Fshare%2F<shareId>&bl=<cfb2h>&hl=fr&_reqid=12345&rt=c"
   ```
3. Locate the line beginning with `[["wrb.fr","ujx1Bf",`, JSON-decode element `[0][2]`, and iterate over `data[0][1]` (`turn[2][0][0]` = user prompt, `turn[3][0][0][1][0]` = model response).

## Verification
- [ ] Script exits with code `0` and logs the conversation title and non-zero turn count to `stderr`.
- [ ] Output Markdown file contains each turn's user prompt and Gemini response.
- [ ] Any empty model text (`model_len=0`, e.g., when a turn generated an external canvas/doc) includes fallback metadata extracted from `turn[3][4]`.
