"""Generic browser smoke for a `labelle bundle --platform=wasm` output.

Used by the builder image's CI (docs/wasm-builder-image.md): serves the bundle
on localhost, opens it in Playwright's headless Chromium (SwiftShader WebGL,
as Flying Platform's smoke does) and checks that the game starts:

  * with --isolated the page is served with COOP/COEP, must be
    crossOriginIsolated and must load the threaded build (threaded/game.js);
    without it, it must load the single-threaded fallback (game.js);
  * labelle-web's loader reaches onRuntimeInitialized (its #loading overlay
    is hidden and not marked failed);
  * no uncaught page error or Emscripten abort, then or during --settle
    seconds of running.

Writes result.json, console.log and screenshot.png to --output.
"""
import argparse
import asyncio
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time

from playwright.async_api import async_playwright

GL_ARGS = ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]


class Handler(SimpleHTTPRequestHandler):
    isolated = False
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        if self.isolated:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()

    def log_message(self, *args):
        pass


async def run(opts):
    out = Path(opts.output)
    out.mkdir(parents=True, exist_ok=True)
    handler = type("H", (Handler,), {"isolated": opts.isolated})
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(handler, directory=opts.bundle))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/index.html"

    console, errors, scripts = [], [], []
    result = {"url": url, "isolated": opts.isolated, "ok": False}
    start = time.monotonic()
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=GL_ARGS)
        result["browser"] = browser.version
        page = await browser.new_page(viewport={"width": 1024, "height": 768})
        page.on("console", lambda m: console.append(f"[{m.type}] {m.text}"))
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("request", lambda r: scripts.append(r.url) if r.url.endswith("game.js") else None)
        try:
            await page.goto(url)
            await page.wait_for_function(
                "() => { const o = document.getElementById('loading');"
                " return !o || o.hidden || o.classList.contains('failed'); }",
                timeout=opts.timeout * 1000)
            result["started_seconds"] = round(time.monotonic() - start, 1)
            await page.wait_for_timeout(opts.settle * 1000)
            state = await page.evaluate(
                "() => ({ isolated: self.crossOriginIsolated === true,"
                " failed: !!document.getElementById('loading')?.classList.contains('failed'),"
                " status: document.getElementById('loading-status')?.textContent || '',"
                " sab: typeof SharedArrayBuffer !== 'undefined' })")
            result.update(state)
            await page.screenshot(path=str(out / "screenshot.png"))
        except Exception as e:  # timeout or navigation failure
            errors.append(f"smoke: {type(e).__name__}: {e}")
        finally:
            await browser.close()
            server.shutdown()

    want = "threaded/game.js" if opts.isolated else "/game.js"
    loaded = [s for s in scripts if s.endswith(want) and (opts.isolated or "/threaded/" not in s)]
    result.update(scripts=scripts, errors=errors, seconds=round(time.monotonic() - start, 1))
    problems = list(errors)
    if result.get("failed"):
        problems.append(f"loader reported failure: {result.get('status')!r}")
    if result.get("isolated") != opts.isolated:
        problems.append(f"crossOriginIsolated is {result.get('isolated')}, expected {opts.isolated}")
    if not loaded:
        problems.append(f"expected the page to load {want}, it loaded {scripts}")
    result["problems"] = problems
    result["ok"] = not problems
    (out / "console.log").write_text("\n".join(console) + "\n", encoding="utf-8")
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if result["ok"] else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--isolated", action="store_true", help="serve with COOP/COEP and expect the threaded build")
    ap.add_argument("--timeout", type=int, default=120, help="seconds to reach onRuntimeInitialized")
    ap.add_argument("--settle", type=int, default=10, help="seconds to keep running after start")
    raise SystemExit(asyncio.run(run(ap.parse_args())))


if __name__ == "__main__":
    main()
