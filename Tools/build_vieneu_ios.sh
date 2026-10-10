#!/usr/bin/env bash
# =============================================================================
#  build_vieneu_ios.sh — dựng VieNeu-TTS cho ViPath (iPhone, offline)
#
#  Chạy trên Mac, từ thư mục gốc dự án:
#      cd ~/Documents/ViPathTranslate && bash Tools/build_vieneu_ios.sh
#
#  Việc script làm:
#    1. Kiểm tra / cài công cụ: Xcode CLT, Homebrew, cmake, ninja, Rust (rustup)
#    2. Tải mã nguồn audio.cpp + sea-g2p (ghim đúng commit đã kiểm thử)
#    3. Build sea-g2p (Rust) → Frameworks/SeaG2P.xcframework   (thư viện tĩnh)
#    4. Build audio.cpp (C API, chỉ họ VieNeu, CPU) → Frameworks/AudioCpp.xcframework
#       (kèm AudioCpp.framework.dSYM để App Store Connect giải mã báo cáo crash)
#    5. Tải mô hình VieNeu-TTS v3 Turbo Q8_0 + giọng mặc định + từ điển sea_g2p.bin
#       → ViPathTranslate/Resources/VieNeu/   (Xcode tự đóng gói vào app)
#    6. Gắn 2 XCFramework vào dự án Xcode (HÃY THOÁT XCODE TRƯỚC KHI CHẠY)
#
#  Chạy lại an toàn: bước nào đã xong sẽ được bỏ qua (xoá build/vieneu để làm lại).
#  Chỉ dựng lại AudioCpp (vd. để có dSYM):  bash Tools/build_vieneu_ios.sh --audiocpp
# =============================================================================
set -euo pipefail

AUDIOCPP_COMMIT="c7f5743f037d588049c63aa75e9b4fdb279cfe01"   # 2026-10-08, có C API 0.2
SEAG2P_COMMIT="e825173f235d08ea19315b2b279fb11153b44cea"     # 2026-09-23, ABI 1
HF_BASE="https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo/resolve/main/gguf"
IOS_MIN="17.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/vieneu"
OUT_FW="$ROOT/Frameworks"
OUT_RES="$ROOT/ViPathTranslate/Resources/VieNeu"
LOG="$WORK/build.log"
mkdir -p "$WORK" "$OUT_FW" "$OUT_RES"
: > "$LOG"

step() { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m✗ %s\033[0m\n  Xem chi tiết: %s\n" "$*" "$LOG"; exit 1; }
run()  { "$@" >>"$LOG" 2>&1 || die "Lệnh thất bại: $*"; }

ONLY_AUDIOCPP=0
[[ "${1:-}" == "--audiocpp" ]] && ONLY_AUDIOCPP=1

[[ "$(uname -s)" == "Darwin" ]] || die "Script này chạy trên macOS."
[[ "$(uname -m)" == "arm64" ]] || echo "  (cảnh báo: Mac không phải Apple Silicon — vẫn thử tiếp)"

# -----------------------------------------------------------------------------
step "1/6 Kiểm tra công cụ"
xcode-select -p >/dev/null 2>&1 || die "Chưa có Xcode Command Line Tools: chạy 'xcode-select --install' rồi chạy lại."
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die "Không thấy iOS SDK. Mở Xcode một lần, hoặc: sudo xcode-select -s /Applications/Xcode.app"
ok "Xcode: $(xcodebuild -version | head -1)"

# cmake + ninja: dùng Homebrew nếu có; nếu không, cài bằng pip vào thư mục người dùng
# (không cần quyền quản trị, không cần Homebrew).
if ! command -v brew >/dev/null 2>&1; then
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x $p ]] && eval "$($p shellenv)"; done
fi
PYUSER_BIN="$(/usr/bin/python3 -c 'import site,os;print(os.path.join(site.USER_BASE,"bin"))' 2>/dev/null || true)"
[[ -n "$PYUSER_BIN" ]] && export PATH="$PYUSER_BIN:$PATH"
for tool in cmake ninja; do
  if ! command -v $tool >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      echo "  Đang cài $tool (Homebrew)…"; run brew install $tool
    else
      echo "  Đang cài $tool (pip, chỉ cho tài khoản này)…"
      run /usr/bin/python3 -m pip install --user --upgrade $tool
    fi
  fi
  command -v $tool >/dev/null 2>&1 || die "Không cài được $tool."
done
ok "cmake $(cmake --version | head -1 | awk '{print $3}'), ninja $(ninja --version)"

if ! command -v rustup >/dev/null 2>&1; then
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "  Đang cài Rust (rustup, chỉ cho tài khoản người dùng này)…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >>"$LOG" 2>&1 \
    || die "Cài rustup thất bại."
  source "$HOME/.cargo/env"
fi
run rustup target add aarch64-apple-ios aarch64-apple-ios-sim
ok "$(rustc --version)"

# -----------------------------------------------------------------------------
step "2/6 Tải mã nguồn"
# Luôn tải qua HTTPS công khai: bỏ qua cấu hình git toàn cục của máy
# (vd. url.insteadOf chuyển github.com sang SSH, đòi khoá SSH / hỏi fingerprint).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
fetch_repo() { # url dir commit
  local url=$1 dir=$2 commit=$3
  if [[ ! -d "$dir/.git" ]]; then
    run git init -q "$dir"
    run git -C "$dir" remote add origin "$url"
  fi
  if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]]; then
    run git -C "$dir" fetch -q --depth 1 origin "$commit"
    run git -C "$dir" checkout -q --force FETCH_HEAD
    # Không cần submodule (chỉ là giao diện web của server; dùng SSH nên sẽ đòi khoá).
  fi
  ok "$(basename "$dir") @ ${commit:0:8}"
}
fetch_repo https://github.com/0xShug0/audio.cpp.git "$WORK/audio.cpp" "$AUDIOCPP_COMMIT"
fetch_repo https://github.com/pnnbao97/sea-g2p.git  "$WORK/sea-g2p"   "$SEAG2P_COMMIT"

# -----------------------------------------------------------------------------
step "3/6 Build sea-g2p (Rust) → SeaG2P.xcframework"
if [[ ! -d "$OUT_FW/SeaG2P.xcframework" ]]; then
  export IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN"
  for t in aarch64-apple-ios aarch64-apple-ios-sim; do
    echo "  cargo → $t (vài phút)…"
    (cd "$WORK/sea-g2p" && cargo rustc --release --lib --crate-type staticlib \
        --no-default-features --features capi --target "$t") >>"$LOG" 2>&1 \
      || die "Build sea-g2p cho $t thất bại."
  done
  H="$WORK/seag2p-headers"; rm -rf "$H"; mkdir -p "$H"
  cp "$WORK/sea-g2p/include/sea_g2p.h" "$H/"
  cat > "$H/module.modulemap" <<'EOF'
module SeaG2P {
    header "sea_g2p.h"
    export *
}
EOF
  run xcodebuild -create-xcframework \
    -library "$WORK/sea-g2p/target/aarch64-apple-ios/release/libsea_g2p_rs.a" -headers "$H" \
    -library "$WORK/sea-g2p/target/aarch64-apple-ios-sim/release/libsea_g2p_rs.a" -headers "$H" \
    -output "$OUT_FW/SeaG2P.xcframework"
fi
ok "Frameworks/SeaG2P.xcframework"

# -----------------------------------------------------------------------------
step "4/6 Build audio.cpp (C API, VieNeu, CPU) → AudioCpp.xcframework"
# sentencepiece (bên trong audio.cpp) gọi set_xcode_property — macro chỉ có trong toolchain
# iOS riêng của nó. Định nghĩa macro rỗng, nạp sau mỗi project() qua CMAKE_PROJECT_INCLUDE.
SHIM="$WORK/ios_shim.cmake"
cat > "$SHIM" <<'EOF2'
if(NOT COMMAND set_xcode_property)
  macro(set_xcode_property)
  endmacro()
endif()
EOF2

AUDIOCPP_LIB=""
build_audiocpp() { # sdk  → đặt AUDIOCPP_LIB = đường dẫn libaudiocpp đã build
  local sdk=$1 bdir="$WORK/audiocpp-$1" arch
  # Bản build cũ không có thông tin gỡ lỗi (-g) → không tạo được dSYM → build lại
  [[ -f "$bdir/.done" && ! -f "$bdir/.debuginfo" ]] && rm -rf "$bdir"
  # Bật lệnh SIMD cho phép nhân Q8_0 nhanh (cross-compile nên ggml không tự dò được).
  # iPhone 18 (A20): armv8.6 + dotprod + i8mm + fp16. Simulator: an toàn cho mọi Mac M-series.
  if [[ $sdk == iphoneos ]]; then arch="armv8.6-a+dotprod+i8mm+fp16"; else arch="armv8.4-a+dotprod+fp16"; fi
  if [[ ! -f "$bdir/.done" ]]; then
    rm -rf "$bdir"   # bỏ cấu hình hỏng của lần chạy trước
    echo "  cmake → $sdk (lần đầu ~5–15 phút)…"
    run cmake -S "$WORK/audio.cpp" -B "$bdir" -G Ninja \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_SYSROOT="$sdk" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_PROJECT_INCLUDE="$SHIM" \
      -DGGML_CPU_ARM_ARCH="$arch" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="-g" -DCMAKE_CXX_FLAGS="-g" \
      -DAUDIOCPP_BUILD_C_API=ON \
      -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=vieneu_v3_turbo \
      -DAUDIOCPP_DEPLOYMENT_BUILD=ON \
      -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=OFF \
      -DENGINE_ENABLE_METAL=OFF -DENGINE_ENABLE_OPENMP=OFF \
      -DENGINE_ENABLE_NATIVE_CPU=OFF -DENGINE_ENABLE_VULKAN=OFF \
      -DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_HIP=OFF \
      -DENGINE_BUILD_EXAMPLES=OFF -DENGINE_BUILD_TESTS=OFF
    run cmake --build "$bdir" --target audiocpp -j "$(sysctl -n hw.ncpu)"
    touch "$bdir/.done" "$bdir/.debuginfo"
  fi
  # file thật (không phải symlink)
  local lib; lib="$(find "$bdir" -name 'libaudiocpp*.dylib' -type f | head -1)"
  [[ -n "$lib" ]] || die "Không tìm thấy libaudiocpp.dylib sau khi build ($sdk)."
  AUDIOCPP_LIB="$lib"
}
make_framework() { # dylib  platform(iPhoneOS|iPhoneSimulator)  outdir
  local lib=$1 plat=$2 out=$3/AudioCpp.framework dsym=$3/AudioCpp.framework.dSYM
  rm -rf "$out" "$dsym"; mkdir -p "$out/Headers" "$out/Modules"
  cp "$lib" "$out/AudioCpp"
  install_name_tool -id @rpath/AudioCpp.framework/AudioCpp "$out/AudioCpp"
  # dSYM: gom thông tin gỡ lỗi từ các tệp .o (UUID trùng với tệp nhị phân), rồi bỏ phần
  # gỡ lỗi khỏi tệp nhị phân trong app (strip -S giữ nguyên UUID và các ký hiệu xuất).
  run xcrun dsymutil "$out/AudioCpp" -o "$dsym"
  run xcrun strip -S "$out/AudioCpp"
  local u1 u2
  u1="$(xcrun dwarfdump --uuid "$out/AudioCpp" | awk '{print $2}')"
  u2="$(xcrun dwarfdump --uuid "$dsym" | awk '{print $2}')"
  [[ -n "$u1" && "$u1" == "$u2" ]] || die "UUID của dSYM ($u2) không khớp AudioCpp ($u1)."
  ok "dSYM $plat · UUID $u1"
  cp "$WORK/audio.cpp/include/audiocpp.h" "$out/Headers/"
  cat > "$out/Modules/module.modulemap" <<'EOF'
framework module AudioCpp {
    umbrella header "audiocpp.h"
    export *
}
EOF
  cat > "$out/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AudioCpp</string>
  <key>CFBundleIdentifier</key><string>vn.quangminh.vipath.audiocpp</string>
  <key>CFBundleName</key><string>AudioCpp</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
  <key>MinimumOSVersion</key><string>$IOS_MIN</string>
</dict></plist>
EOF
}
# XCFramework cũ (chưa kèm dSYM) → dựng lại
if [[ -d "$OUT_FW/AudioCpp.xcframework" && ! -d "$OUT_FW/AudioCpp.xcframework/ios-arm64/dSYMs" ]]; then
  echo "  AudioCpp.xcframework chưa có dSYM → dựng lại"
  rm -rf "$OUT_FW/AudioCpp.xcframework"
fi
if [[ ! -d "$OUT_FW/AudioCpp.xcframework" ]]; then
  build_audiocpp iphoneos;        LIB_IOS="$AUDIOCPP_LIB"
  build_audiocpp iphonesimulator; LIB_SIM="$AUDIOCPP_LIB"
  make_framework "$LIB_IOS" iPhoneOS        "$WORK/fw-ios"
  make_framework "$LIB_SIM" iPhoneSimulator "$WORK/fw-sim"
  # -debug-symbols cần đường dẫn tuyệt đối; Xcode tự chép dSYM này vào bản Archive
  run xcodebuild -create-xcframework \
    -framework "$WORK/fw-ios/AudioCpp.framework" -debug-symbols "$WORK/fw-ios/AudioCpp.framework.dSYM" \
    -framework "$WORK/fw-sim/AudioCpp.framework" -debug-symbols "$WORK/fw-sim/AudioCpp.framework.dSYM" \
    -output "$OUT_FW/AudioCpp.xcframework"
fi
ok "Frameworks/AudioCpp.xcframework ($(du -sh "$OUT_FW/AudioCpp.xcframework" | cut -f1), kèm dSYM)"
if [[ $ONLY_AUDIOCPP == 1 ]]; then
  printf "\n\033[1;32m✔ Xong AudioCpp.\033[0m Trong Xcode: Product → Clean Build Folder (⇧⌘K), rồi Archive lại.\n\n"
  exit 0
fi

# -----------------------------------------------------------------------------
step "5/6 Tải mô hình VieNeu-TTS v3 Turbo (≈190 MB) + từ điển sea-g2p (≈63 MB)"
dl() { # url dest
  if [[ ! -s "$2" ]]; then
    echo "  ↓ $(basename "$2")"
    curl -L --fail --retry 3 --progress-bar -o "$2.part" "$1" || die "Tải thất bại: $1"
    mv "$2.part" "$2"
  fi
}
dl "$HF_BASE/vieneu-v3-turbo-q8_0.gguf"                "$OUT_RES/vieneu-v3-turbo-q8_0.gguf"
dl "$HF_BASE/voices/minh_quan_pro/ref_codes.txt"       "$OUT_RES/vieneu_ref_codes.txt"
dl "$HF_BASE/voices/minh_quan_pro/speaker.emb.txt"     "$OUT_RES/vieneu_speaker.emb.txt"
[[ -s "$OUT_RES/sea_g2p.bin" ]] || cp "$WORK/sea-g2p/python/sea_g2p/sea_g2p.bin" "$OUT_RES/sea_g2p.bin"
ok "ViPathTranslate/Resources/VieNeu ($(du -sh "$OUT_RES" | cut -f1))"

# -----------------------------------------------------------------------------
step "6/6 Gắn XCFramework vào dự án Xcode"
if grep -q "D10000000000000000000001" "$ROOT/ViPathTranslate.xcodeproj/project.pbxproj"; then
  ok "Đã gắn từ trước — bỏ qua"
  printf "\n\033[1;32m✔ Xong.\033[0m Trong Xcode: Product → Clean Build Folder (⇧⌘K), rồi chạy / Archive lại.\n\n"
  exit 0
fi
if pgrep -xq Xcode; then
  echo "  ⚠️  Xcode đang mở. Hãy THOÁT Xcode (⌘Q) rồi nhấn Enter để tiếp tục…"
  read -r _
fi
run /usr/bin/python3 "$ROOT/Tools/add_vieneu_to_xcodeproj.py" "$ROOT/ViPathTranslate.xcodeproj/project.pbxproj"
ok "Đã thêm AudioCpp.xcframework (nhúng) + SeaG2P.xcframework (tĩnh) vào target ViPathTranslate"

printf "\n\033[1;32m✔ Xong.\033[0m Mở lại ViPathTranslate.xcodeproj, chọn iPhone, bấm ▶.\n"
printf "  Trong app: tab Dịch → nút sóng âm (Giọng đọc) góc trên bên phải.\n\n"
