#!/bin/bash
# 開発者向けパック（packs/developer.txt）を変えた前後で、用語の正解率を同じ区間・同じ語で比べる。
# compare-terms を 2 回回す（前 = <base> の developer.txt、後 = 作業ツリーの developer.txt）。
# どちらも、前後どちらかのパックにある語をすべて採点する（--extra-terms）。外れた語と出た形も残す（--forms、本文は残さない）。
#
#   eval/compare_pack_change.sh [base（既定 origin/main）]
#
# whisper turbo で、試験セット（~/Library/Application Support/Koe/corpus）の用語が出る区間を 4 条件 × 2 回起こす。
# ほかの作業を邪魔しないよう、薄く長く回す: nice -n 19、whisper は 2 スレッド、1 区間ごとに 1 秒休む。1 本ずつ流す。
# 結果は ~/Library/Application Support/Koe/evals/pack-change-<日時>/（リポジトリの外）に書く。
set -euo pipefail
cd "$(dirname "$0")/.."
base="${1:-origin/main}"
out="$HOME/Library/Application Support/Koe/evals/pack-change-$(date +%Y%m%d-%H%M)"
mkdir -p "$out"
git show "$base:packs/developer.txt" > "$out/developer.before.txt"
cp packs/developer.txt "$out/developer.after.txt"
# Each run picks a free port for its own whisper-server, so parallel runs need no setting.
export KOE_EVAL_SERVER_ARGS="${KOE_EVAL_SERVER_ARGS:--t 2}"
echo "$(date '+%F %T') before ($base)" | tee "$out/log.txt"
nice -n 19 python3 eval/koe_bench.py compare-terms --developer "$out/developer.before.txt" \
    --extra-terms "$out/developer.after.txt" --forms "$out/before.json" --sleep 1 > "$out/before.txt"
echo "$(date '+%F %T') after (working tree)" | tee -a "$out/log.txt"
nice -n 19 python3 eval/koe_bench.py compare-terms --developer "$out/developer.after.txt" \
    --extra-terms "$out/developer.before.txt" --forms "$out/after.json" --sleep 1 > "$out/after.txt"
echo "$(date '+%F %T') done" | tee -a "$out/log.txt"
grep "用語の正解率" "$out/before.txt" "$out/after.txt" | sed "s|$out/||"
echo "-> $out"
