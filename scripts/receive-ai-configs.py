#!/usr/bin/env python3
"""HTTP nhận file cấu hình AI tool 1-lần-dùng — dùng bởi bước "khôi phục cấu hình"
trong setup.sh khi cài telecode trên máy mới (xem plan đồng bộ AI config).

Không thêm dependency (chỉ http.server chuẩn thư viện) — cùng pattern với wizard.py.
In ra 1 dòng JSON {"code": "..."} rồi chạy tới khi nhận đúng 1 file hợp lệ có
?code=<mã đó> thì ghi ra <output-file> và thoát (exit 0). Không có timeout riêng —
setup.sh (bash) chịu trách nhiệm kill tiến trình này nếu người dùng không thao tác
kịp trong thời gian chờ.

Usage: python3 receive-ai-configs.py <output-file> <port>
"""
import cgi
import json
import secrets
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def main() -> None:
    if len(sys.argv) != 3:
        print("Usage: receive-ai-configs.py <output-file> <port>", file=sys.stderr)
        sys.exit(1)
    out_path, port = sys.argv[1], int(sys.argv[2])
    code = secrets.token_urlsafe(16)
    state = {"done": False}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # im lặng, tránh rác log ra stdout (dòng đầu là JSON cho bash đọc)
            pass

        def do_POST(self):
            query_code = self.path.split("?code=", 1)[-1] if "?code=" in self.path else ""
            if query_code != code or state["done"]:
                self.send_response(403)
                self.end_headers()
                return
            ctype, pdict = cgi.parse_header(self.headers.get("Content-Type", ""))
            if ctype != "multipart/form-data":
                self.send_response(400)
                self.end_headers()
                return
            pdict["boundary"] = pdict["boundary"].encode()
            pdict["CONTENT-LENGTH"] = int(self.headers.get("Content-Length", 0))
            form = cgi.parse_multipart(self.rfile, pdict)
            data = form.get("file", [None])[0]
            if not data:
                self.send_response(400)
                self.end_headers()
                return
            with open(out_path, "wb") as f:
                f.write(data if isinstance(data, bytes) else data.encode("latin1"))
            state["done"] = True
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK - da nhan file, co the dong terminal nay lai.")

    # Dòng đầu tiên ra stdout LUÔN là JSON để setup.sh (bash) đọc lại mã 1-lần-dùng.
    print(json.dumps({"code": code}), flush=True)

    server = HTTPServer(("127.0.0.1", port), Handler)
    while not state["done"]:
        server.handle_request()


if __name__ == "__main__":
    main()
