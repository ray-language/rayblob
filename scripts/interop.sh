#!/bin/sh
# rayblob against the real aws-cli: a fresh server on a random high port with a temporary data
# directory, every operation the CLI uses, a 200 MB multipart upload and download compared byte
# for byte, and the server's peak memory. Usage: scripts/interop.sh   (needs ./rayblob: make build)
set -eu
BIN="$(cd "$(dirname "$0")/.." && pwd)/rayblob"
command -v aws >/dev/null || { echo "interop: needs aws-cli" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rayblob-interop.XXXXXX")"
PORT=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 20000))
cat > "$WORK/rayblob.toml" <<EOF
[server]
listen = "127.0.0.1:$PORT"
data = "$WORK/data"

[key.admin]
access = "AKRBINTEROP000001"
secret = "interop-secret"

[key.reader]
access = "AKRBINTEROP000002"
secret = "reader-secret"
buckets = ["other"]
write = false
EOF
export AWS_ACCESS_KEY_ID=AKRBINTEROP000001 AWS_SECRET_ACCESS_KEY=interop-secret AWS_DEFAULT_REGION=us-east-1
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
EP="http://127.0.0.1:$PORT"

"$BIN" serve --config "$WORK/rayblob.toml" >"$WORK/serve.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT
i=0
until curl -s -o /dev/null "$EP"; do
    i=$((i + 1)); [ $i -gt 50 ] && { cat "$WORK/serve.log"; exit 1; }
    sleep 0.1
done

PEAK=0
peak() {
    r=$(ps -o rss= -p "$SRV" | tr -d ' ')
    [ "$r" -gt "$PEAK" ] && PEAK=$r
    return 0
}
pass=0
check() { # check NAME COMMAND...: the command must succeed
    name=$1; shift
    if "$@" >"$WORK/out" 2>&1; then pass=$((pass + 1)); printf "  ok    %s\n" "$name"
    else printf "  FAIL  %s\n" "$name"; sed 's/^/        /' "$WORK/out"; exit 1; fi
}
fails_with() { # fails_with NAME CODE COMMAND...: the command must fail with that S3 error code
    name=$1; code=$2; shift 2
    if "$@" >"$WORK/out" 2>&1; then printf "  FAIL  %s (succeeded)\n" "$name"; exit 1; fi
    if grep -q "($code)" "$WORK/out"; then pass=$((pass + 1)); printf "  ok    %s\n" "$name"
    else printf "  FAIL  %s\n" "$name"; sed 's/^/        /' "$WORK/out"; exit 1; fi
}
S() { aws --endpoint-url "$EP" s3 "$@"; }
A() { aws --endpoint-url "$EP" s3api "$@"; }

echo "rayblob interop with $(aws --version 2>&1 | cut -d' ' -f1) on $EP"
printf 'hello\n' >"$WORK/h.txt"
mkdir -p "$WORK/tree/a/b"; for n in 1 2 3; do echo $n >"$WORK/tree/a/f$n"; echo $n >"$WORK/tree/a/b/g$n"; done

check "create-bucket" A create-bucket --bucket demo
fails_with "create-bucket twice" BucketAlreadyOwnedByYou A create-bucket --bucket demo
fails_with "bad bucket name" InvalidBucketName A create-bucket --bucket Bad_Name
check "list-buckets" sh -c "aws --endpoint-url $EP s3api list-buckets | grep -q '\"demo\"'"
check "put-object with metadata" A put-object --bucket demo --key 'dir/hello world.txt' --body "$WORK/h.txt" --content-type text/plain --metadata owner=ray
check "head-object" sh -c "aws --endpoint-url $EP s3api head-object --bucket demo --key 'dir/hello world.txt' | grep -q '\"owner\": \"ray\"'"
check "get-object range" sh -c "aws --endpoint-url $EP s3api get-object --bucket demo --key 'dir/hello world.txt' --range bytes=1-3 $WORK/r >/dev/null && [ \"\$(cat $WORK/r)\" = ell ]"
fails_with "missing key" NoSuchKey A get-object --bucket demo --key nope "$WORK/x"
check "sync a tree" S sync "$WORK/tree" s3://demo/tree/
check "ls recursive" sh -c "aws --endpoint-url $EP s3 ls s3://demo/tree/ --recursive | wc -l | grep -q 6"
check "ls with delimiter" sh -c "aws --endpoint-url $EP s3 ls s3://demo/tree/a/ | grep -q 'PRE b/'"
check "copy-object" A copy-object --bucket demo --key copy.txt --copy-source 'demo/dir/hello world.txt'
check "rm recursive (DeleteObjects)" S rm s3://demo/tree/ --recursive
fails_with "delete non-empty bucket" BucketNotEmpty A delete-bucket --bucket demo
check "presigned GET by curl" sh -c "curl -sf \"\$(aws --endpoint-url $EP s3 presign 's3://demo/dir/hello world.txt' --expires-in 60)\" | grep -q hello"
check "presigned PUT by curl" sh -c "curl -sf -X PUT --data-binary 'by url' \"\$('$BIN' presign --config $WORK/rayblob.toml --method PUT --expires 60 demo/up.txt)\""
check "public-read for anonymous" sh -c "aws --endpoint-url $EP s3api put-object --bucket demo --key pub --body $WORK/h.txt --acl public-read >/dev/null && curl -sf $EP/demo/pub | grep -q hello"
check "private for anonymous" sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $EP/demo/copy.txt)\" = 403 ]"
fails_with "reader without the bucket" AccessDenied env AWS_ACCESS_KEY_ID=AKRBINTEROP000002 AWS_SECRET_ACCESS_KEY=reader-secret aws --endpoint-url "$EP" s3api list-objects-v2 --bucket demo
fails_with "wrong secret" SignatureDoesNotMatch env AWS_SECRET_ACCESS_KEY=wrong aws --endpoint-url "$EP" s3 ls

head -c 200000000 /dev/urandom >"$WORK/big.bin"
( while kill -0 "$SRV" 2>/dev/null && [ ! -e "$WORK/stop" ]; do peak; ps -o rss= -p "$SRV" >>"$WORK/rss"; sleep 0.2; done ) &
t0=$(date +%s)
check "200 MB multipart upload" S cp "$WORK/big.bin" s3://demo/big.bin --only-show-errors
t1=$(date +%s)
check "200 MB download, same bytes" sh -c "aws --endpoint-url $EP s3 cp s3://demo/big.bin $WORK/big.out --only-show-errors && cmp $WORK/big.bin $WORK/big.out"
t2=$(date +%s)
touch "$WORK/stop"
check "multipart ETag" sh -c "aws --endpoint-url $EP s3api head-object --bucket demo --key big.bin | grep ETag | grep -qE -- '-[0-9]+'"
check "single-part ETag is the MD5" sh -c "aws --endpoint-url $EP s3api head-object --bucket demo --key pub | grep -q \"\$(md5 -q $WORK/h.txt 2>/dev/null || md5sum $WORK/h.txt | cut -d' ' -f1)\""
top=$(sort -n "$WORK/rss" | tail -1)
echo "$pass checks passed; 200 MB up in $((t1 - t0)) s, down in $((t2 - t1)) s; server peak RSS $((top / 1024)) MiB"
