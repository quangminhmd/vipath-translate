#!/bin/bash
# Mở ViPath Web qua máy chủ cục bộ (http://localhost) để trình duyệt lưu mô hình đã tải và cho dùng micro.
# macOS: bấm đúp tệp này. Dừng: đóng cửa sổ Terminal.
cd "$(dirname "$0")"
PORT=8765
( sleep 1; open "http://localhost:$PORT/ViPath.html" ) &
python3 -m http.server $PORT --bind 127.0.0.1
