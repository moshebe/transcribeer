# ivrit.ai Hebrew voice sample

Test sample for comparing transcription output against an authoritative
Hebrew reference transcript.

## Source

- Dataset: [`ivrit-ai/audio-v2-40s`](https://huggingface.co/datasets/ivrit-ai/audio-v2-40s)
  (subset of `ivrit-ai/audio-v2` sliced to ≤40s chunks for training/eval)
- Project: [github.com/ivrit-ai/ivrit.ai](https://github.com/ivrit-ai/ivrit.ai)
- License: ivrit.ai License — permissive, allows research & commercial use
  (<https://www.ivrit.ai/en/the-license/>)
- Sample id: `00029c29-ae3c-43d5-9fad-2734531829e0`

## Files

| file | notes |
|------|-------|
| `sample_30s_he.wav` | 16 kHz mono PCM, 31.68s (closest to 30s in shard) |
| `sample_30s_he.txt` | reference transcript (Hebrew) |

The shard provides the authoritative text alongside the audio — generated
via ivrit.ai's pipeline: VAD + Whisper-large-v3-turbo-ct2 + Stable-Whisper
text/audio alignment with quality filtering. It is the same data used to
train their Hebrew Whisper models.

## Reference transcript

```
 יפה.  טוב,  יושב-ראש הסתדרות,  ארנון בר דוד,  היה כיף שבאת.  וואללה.  תודה רבה לך.  תודה.  מה השביתה הבאה?  מתי?  על מה?  אתה לא מהמר.  יש משהו על המדינה משוגעת, בוא נראה מה ילד יום.  טוב, אז תודה שבאת, זה היה פרק 273.  אנחנו נהיה איתכם כאן עם מוסף בהמשך השבוע.  רק אני רוצה לוודא באמת שזה היה 273, כבר שכחתי.  כן, זה היה פרק 273. אז אנחנו נהיה איתכם במוסף,  וזהו, שיהיה שבוע טוב ושקט.  ביי ביי.
```

## How to fetch fresh samples

```bash
# 200 Hebrew 30–40s clips with transcripts (~230 MB):
curl -L -o shard.tar \
  https://huggingface.co/datasets/ivrit-ai/audio-v2-40s/resolve/main/data/shard-000000-of-000001.tar
tar -xf shard.tar
# Each sample: <uuid>.wav + <uuid>.txt + <uuid>.duration (float64 little-endian)
```

Other useful ivrit-ai datasets:

- `ivrit-ai/eval-d1` — expert-reviewed eval set (gated, click-to-accept)
- `ivrit-ai/eval-whatsapp` — 54 Hebrew WhatsApp voice messages, expert
  transcribed (gated)
- `ivrit-ai/crowd-transcribe-v5` — 100K+ crowd-transcribed clips (gated)
- `ivrit-ai/knesset-plenums-whisper-training` — parliamentary recordings
