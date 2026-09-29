package_app_icon() {
    local resources="$1"
    local iconset="$ROOT/.build/Micky.iconset"
    local size doubled

    mkdir -p "$ROOT/.build" "$resources"
    rm -rf "$iconset"
    mkdir -p "$iconset"

    for size in 16 32 128 256 512; do
        doubled=$((size * 2))
        sips -z "$size" "$size" "$ROOT/icons/mic.png" \
            --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z "$doubled" "$doubled" "$ROOT/icons/mic.png" \
            --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$iconset" -o "$resources/Micky.icns"
    rm -rf "$iconset"
}
