#!/usr/bin/env bash
set -uo pipefail

# ==========================================
# MinIO Batch Anonymous Policy Manager
# ==========================================

MC="${MC:-./mc}"
ALIAS="${MINIO_ALIAS:-minio}"
BUCKET_FILE="${BUCKET_FILE:-./buckets.txt}"
BACKUP_ROOT="${BACKUP_ROOT:-./minio-policy-backups}"
MODE="${1:---check}"

if [[ "$MODE" != "--check" && "$MODE" != "--apply" ]]; then
    echo "Usage: $0 [--check|--apply]"
    exit 1
fi

for cmd in jq date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Missing command: $cmd"
        exit 1
    fi
done

if [[ ! -x "$MC" ]]; then
    echo "[ERROR] MinIO client not found: $MC"
    exit 1
fi

if [[ ! -f "$BUCKET_FILE" ]]; then
    echo "[ERROR] Bucket file not found: $BUCKET_FILE"
    exit 1
fi

BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACKUP_DIR" || exit 1
chmod 700 "$BACKUP_DIR"

TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0
PLANNED=0
COMPLIANT=0

# ==========================================
# 分析匿名策略
#
# 下面统计的是策略中的显式 Allow / Deny
# 不代表完整 IAM 有效权限评估
# ==========================================
analyze_policy() {
    local file="$1"
    local bucket="$2"

    jq -r --arg bucket "$bucket" '
      def arr:
        if . == null then []
        elif type == "array" then .
        else [.] end;

      def public:
        . == "*" or
        (
          type == "object" and
          ((.AWS // []) | arr | index("*") != null)
        );

      def actions_match($action):
        (.Action | arr) |
        any(.[]; . == $action or . == "s3:*" or . == "*");

      def resource_match($resource):
        (.Resource | arr) |
        any(.[]; . == $resource or . == "*");

      def grant($action; $resource; $effect):
        any(.Statement | arr | .[];
          .Effect == $effect
          and (.Principal | public)
          and (has("Condition") | not)
          and (has("NotAction") | not)
          and (has("NotResource") | not)
          and (has("NotPrincipal") | not)
          and actions_match($action)
          and resource_match($resource)
        );

      ("arn:aws:s3:::" + $bucket) as $b |
      ($b + "/*") as $o |

      (grant("s3:GetObject"; $o; "Allow")) as $get |
      (grant("s3:ListBucket"; $b; "Allow")) as $list |
      (grant("s3:GetObject"; $o; "Deny")) as $get_deny |
      (grant("s3:ListBucket"; $b; "Deny")) as $list_deny |

      "GET_ALLOW=" + ($get|tostring),
      "LIST_ALLOW=" + ($list|tostring),
      "GET_DENY=" + ($get_deny|tostring),
      "LIST_DENY=" + ($list_deny|tostring)
    ' "$file"
}

# ==========================================
# 生成 GetObject-only 策略
# ==========================================
generate_policy() {
    local bucket="$1"
    local output="$2"

    jq -n --arg bucket "$bucket" '
    {
      Version: "2012-10-17",
      Statement: [
        {
          Sid: "AllowPublicReadOnly",
          Effect: "Allow",
          Principal: {
            AWS: ["*"]
          },
          Action: ["s3:GetObject"],
          Resource: [
            ("arn:aws:s3:::" + $bucket + "/*")
          ]
        }
      ]
    }' > "$output"
}

echo "============================================="
echo " MinIO Anonymous Policy Batch"
echo "============================================="
echo "Alias       : $ALIAS"
echo "Bucket file : $BUCKET_FILE"
echo "Mode        : $MODE"
echo "Backup      : $BACKUP_DIR"
echo "============================================="

# ==========================================
# 读取 buckets.txt
# ==========================================
while IFS= read -r BUCKET || [[ -n "$BUCKET" ]]; do

    BUCKET="${BUCKET%$'\r'}"

    # 去除前后空格
    BUCKET="${BUCKET#"${BUCKET%%[![:space:]]*}"}"
    BUCKET="${BUCKET%"${BUCKET##*[![:space:]]}"}"

    [[ -z "$BUCKET" ]] && continue
    [[ "$BUCKET" == \#* ]] && continue

    if [[ ! "$BUCKET" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
        echo "[SKIP] Invalid bucket name: $BUCKET"
        ((SKIPPED+=1))
        continue
    fi

    ((TOTAL+=1))

    TARGET="${ALIAS}/${BUCKET}"

    ORIGINAL="${BACKUP_DIR}/${BUCKET}.original.json"
    CURRENT="${BACKUP_DIR}/${BUCKET}.current.txt"
    NEW_POLICY="${BACKUP_DIR}/${BUCKET}.new.json"
    VERIFY="${BACKUP_DIR}/${BUCKET}.verified.json"

    echo
    echo "=================================================="
    echo "[BUCKET] $BUCKET"
    echo "=================================================="

    # ==========================================
    # 1. 查询权限摘要
    # ==========================================
    echo
    echo "[1] Current anonymous access:"

    if "$MC" anonymous get "$TARGET" > "$CURRENT" 2>&1; then
        cat "$CURRENT"
    else
        echo "[ERROR] Unable to retrieve anonymous access"
        cat "$CURRENT"
        ((FAILED+=1))
        continue
    fi

    # ==========================================
    # 2. 读取完整策略
    # ==========================================
    echo
    echo "[2] Current Bucket Policy:"

    if ! "$MC" anonymous get-json "$TARGET" \
        > "$ORIGINAL" 2>"${ORIGINAL}.err"; then

        echo "[ERROR] Unable to retrieve policy JSON"
        cat "${ORIGINAL}.err"
        echo "[SKIP] Policy cannot be safely backed up"
        ((FAILED+=1))
        continue
    fi

    if ! jq -e '
      type == "object" and
      (.Statement | type == "array")
    ' "$ORIGINAL" >/dev/null 2>&1; then

        echo "[ERROR] Invalid policy JSON"
        cat "$ORIGINAL"
        ((FAILED+=1))
        continue
    fi

    jq . "$ORIGINAL"

    # ==========================================
    # 3. 分析权限
    # ==========================================
    echo
    echo "[3] Anonymous Permission Analysis:"

    ANALYSIS="$(analyze_policy "$ORIGINAL" "$BUCKET")"

    if [[ $? -ne 0 ]]; then
        echo "[ERROR] Cannot analyze policy"
        ((FAILED+=1))
        continue
    fi

    GET_ALLOW=false
    LIST_ALLOW=false
    GET_DENY=false
    LIST_DENY=false

    while IFS='=' read -r key value; do
        case "$key" in
            GET_ALLOW) GET_ALLOW="$value" ;;
            LIST_ALLOW) LIST_ALLOW="$value" ;;
            GET_DENY) GET_DENY="$value" ;;
            LIST_DENY) LIST_DENY="$value" ;;
        esac
    done <<< "$ANALYSIS"

    echo "GetObject Allow : $GET_ALLOW"
    echo "ListBucket Allow: $LIST_ALLOW"
    echo "GetObject Deny  : $GET_DENY"
    echo "ListBucket Deny : $LIST_DENY"

    # ==========================================
    # 4. 判断策略
    # ==========================================
    echo
    echo "[4] Policy Evaluation:"

    # 只把与目标完全相同的策略认定为符合要求。
    generate_policy "$BUCKET" "$NEW_POLICY"

    if jq -e --slurpfile expected "$NEW_POLICY" \
        '. == $expected[0]' "$ORIGINAL" >/dev/null 2>&1; then

        echo "[OK] Already configured with target policy"
        ((COMPLIANT+=1))
        continue
    fi

    if [[ "$LIST_ALLOW" == "true" ]]; then
        echo "[WARN] Anonymous ListBucket grant detected"
    else
        echo "[INFO] No simple unconditional ListBucket grant detected"
    fi

    if [[ "$GET_ALLOW" == "true" ]]; then
        echo "[INFO] Anonymous GetObject grant detected"
    else
        echo "[INFO] No simple unconditional GetObject grant detected"
    fi

    # ==========================================
    # 5. 检查模式
    # ==========================================
    if [[ "$MODE" == "--check" ]]; then
        echo
        echo "[PLAN] Replace anonymous policy with:"
        echo "       GetObject  : Allow"
        echo "       ListBucket : No Allow"
        echo "       PutObject  : No Allow"
        echo "       DeleteObject: No Allow"
        echo "[PLAN] Existing policy will be replaced in --apply"
        ((PLANNED+=1))
        continue
    fi

    # ==========================================
    # 6. 应用权限
    # ==========================================
    echo
    echo "[5] Applying new policy..."

    if ! "$MC" anonymous set-json "$NEW_POLICY" "$TARGET"; then
        echo "[ERROR] Failed to apply policy"
        ((FAILED+=1))
        continue
    fi

    # ==========================================
    # 7. 验证策略
    # ==========================================
    if ! "$MC" anonymous get-json "$TARGET" > "$VERIFY"; then
        echo "[ERROR] Failed to verify policy"
        ((FAILED+=1))
        continue
    fi

    if jq -e --slurpfile expected "$NEW_POLICY" \
        '. == $expected[0]' "$VERIFY" >/dev/null 2>&1; then

        echo "[SUCCESS] Policy verified"
        ((SUCCESS+=1))

    else
        echo "[WARN] Verification mismatch"
        echo "[WARN] Check: $VERIFY"
        ((FAILED+=1))
    fi

done < "$BUCKET_FILE"

echo
echo "============================================="
echo " SUMMARY"
echo "============================================="
echo "Total     : $TOTAL"
echo "Compliant : $COMPLIANT"
echo "Planned   : $PLANNED"
echo "Success   : $SUCCESS"
echo "Skipped   : $SKIPPED"
echo "Failed    : $FAILED"
echo "Backup    : $BACKUP_DIR"
echo "============================================="

if (( FAILED > 0 )); then
    exit 1
fi