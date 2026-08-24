#!/bin/sh
# Safe Hexo build for this low-memory host (1.8GB RAM).
# History: 2026-08-24 the plain `hexo clean && hexo generate && hexo deploy`
# OOM-killed hexo (exit 137) -> empty public/ -> deploy wiped the main branch
# -> whole blog 404 for ~20 minutes. Use THIS script instead.
set -e
cd /tmp/blog_source || exit 1

npx hexo clean

# Low concurrency (-c 2) + bounded V8 heap are mandatory on this host.
# oom_score_adj reset prevents the kernel from picking hexo as first victim.
bash -c 'echo 0 > /proc/self/oom_score_adj; export NODE_OPTIONS="--max-old-space-size=1024"; exec npx hexo generate -c 2' \
  || { echo "BUILD FAILED: hexo generate exited $? (OOM?)"; exit 1; }

# NEVER deploy an empty/incomplete public/ (it wipes the live site).
COUNT=$(find public -name "*.html" | wc -l)
echo "Generated HTML files: $COUNT"
if [ "$COUNT" -lt 1000 ]; then
  echo "ABORT: public/ looks incomplete, refusing to deploy."
  exit 1
fi

npx hexo deploy
echo "DEPLOY OK"
