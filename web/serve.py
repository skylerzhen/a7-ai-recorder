"""测试台本地服务器:GET 发网页;POST /log 把网页抓到的帧写进 captures.ndjson。

这样 eddie 只在 Chrome 里点按钮,所有 TX/RX 帧会回传到本机文件,
agent 直接读 captures.ndjson 就能看到真机字节并解码。不碰蓝牙。
"""

import datetime
import http.server
import json
import os
import socketserver

ROOT = os.path.dirname(os.path.abspath(__file__))
CAP = os.path.join(ROOT, "captures.ndjson")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "content-type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        if self.path != "/log":
            self.send_response(404)
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        try:
            rec = json.loads(body)
            rec["t_server"] = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
            with open(CAP, "a") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except Exception as e:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(str(e).encode())
            return
        self.send_response(204)
        self._cors()
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", 8770), Handler) as httpd:
        print(f"serving {ROOT} on http://127.0.0.1:8770  (captures -> {CAP})")
        httpd.serve_forever()
