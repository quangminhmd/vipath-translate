#!/usr/bin/env python3
"""Gắn Frameworks/AudioCpp.xcframework (động, nhúng + ký) và Frameworks/SeaG2P.xcframework
(tĩnh) vào target ViPathTranslate. Chạy lại nhiều lần vẫn an toàn (idempotent).

    python3 Tools/add_vieneu_to_xcodeproj.py ViPathTranslate.xcodeproj/project.pbxproj

Chỉ chèn thêm dòng tại các mốc cố định của project.pbxproj do ViPath tạo; giữ nguyên mọi
thiết lập anh đã chỉnh trong Xcode (Team, capability…). Tạo bản sao lưu .bak trước khi ghi.
"""
import re
import shutil
import sys

MARK = "D10000000000000000000001"  # nếu đã có → đã gắn rồi

FILE_REFS = """\t\tD10000000000000000000001 /* AudioCpp.xcframework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Frameworks/AudioCpp.xcframework; sourceTree = "<group>"; };
\t\tD10000000000000000000002 /* SeaG2P.xcframework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Frameworks/SeaG2P.xcframework; sourceTree = "<group>"; };
"""
BUILD_FILES = """\t\tD20000000000000000000001 /* AudioCpp.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = D10000000000000000000001 /* AudioCpp.xcframework */; };
\t\tD20000000000000000000002 /* SeaG2P.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = D10000000000000000000002 /* SeaG2P.xcframework */; };
\t\tD20000000000000000000003 /* AudioCpp.xcframework in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = D10000000000000000000001 /* AudioCpp.xcframework */; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
"""
EMBED_PHASE = """\t\tD30000000000000000000001 /* Embed Frameworks */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 10;
\t\t\tfiles = (
\t\t\t\tD20000000000000000000003 /* AudioCpp.xcframework in Embed Frameworks */,
\t\t\t);
\t\t\tname = "Embed Frameworks";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
GROUP = """\t\tD40000000000000000000001 /* Frameworks */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tD10000000000000000000001 /* AudioCpp.xcframework */,
\t\t\t\tD10000000000000000000002 /* SeaG2P.xcframework */,
\t\t\t);
\t\t\tname = Frameworks;
\t\t\tsourceTree = "<group>";
\t\t};
"""

APP_FW_PHASE = "BA0000000000000000000001"   # Frameworks phase của target app
APP_TARGET = "B80000000000000000000001"     # target ViPathTranslate
MAIN_GROUP = "BB0000000000000000000001"


def insert_after(text, anchor, block):
    i = text.find(anchor)
    if i < 0:
        sys.exit(f"Không tìm thấy mốc: {anchor!r} — project.pbxproj đã bị thay đổi cấu trúc.")
    j = i + len(anchor)
    return text[:j] + block + text[j:]


def add_to_list(text, owner_id, key, entry, at_end=False):
    """Thêm `entry` vào danh sách `key = ( ... );` trong object `owner_id`."""
    m = re.search(re.escape(owner_id) + r"[^{]*= \{", text)
    if not m:
        sys.exit(f"Không tìm thấy object {owner_id}")
    k = text.find(f"{key} = (", m.end())
    if k < 0:
        sys.exit(f"Object {owner_id} không có {key}")
    if at_end:
        k = text.find("\t);", k)
        k = text.rfind("\n", 0, k) + 1
    else:
        k = text.find("\n", k) + 1
    return text[:k] + entry + text[k:]


def main(path):
    text = open(path, encoding="utf-8").read()
    if MARK in text:
        print("Đã gắn trước đó — không thay đổi.")
        return
    shutil.copyfile(path, path + ".bak")

    text = insert_after(text, "/* Begin PBXBuildFile section */\n", BUILD_FILES)
    text = insert_after(text, "/* Begin PBXFileReference section */\n", FILE_REFS)
    text = insert_after(text, "/* Begin PBXCopyFilesBuildPhase section */\n", EMBED_PHASE)
    text = insert_after(text, "/* Begin PBXGroup section */\n", GROUP)

    text = add_to_list(text, APP_FW_PHASE, "files",
                       "\t\t\t\tD20000000000000000000001 /* AudioCpp.xcframework in Frameworks */,\n"
                       "\t\t\t\tD20000000000000000000002 /* SeaG2P.xcframework in Frameworks */,\n")
    text = add_to_list(text, APP_TARGET, "buildPhases",
                       "\t\t\t\tD30000000000000000000001 /* Embed Frameworks */,\n", at_end=True)
    text = add_to_list(text, MAIN_GROUP, "children",
                       "\t\t\t\tD40000000000000000000001 /* Frameworks */,\n")

    open(path, "w", encoding="utf-8").write(text)
    print("Đã gắn AudioCpp.xcframework + SeaG2P.xcframework vào target ViPathTranslate.")


if __name__ == "__main__":
    main(sys.argv[1])
