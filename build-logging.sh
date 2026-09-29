if [[ -z "${MICKY_BUILD_LOG_ACTIVE:-}" ]]; then
    MICKY_BUILD_LOG_ACTIVE=1
    export MICKY_BUILD_LOG_ACTIVE
    MICKY_BUILD_LOG="$ROOT/build.log"
    export MICKY_BUILD_LOG
    exec > >(tee "$MICKY_BUILD_LOG") 2>&1
    echo "Writing build output to $MICKY_BUILD_LOG"
fi
