# qark syntax checker: reads [{"name","text"}] as json on stdin, compiles each text
# without running it, and prints [{"ok"} | {"ok":false,"line","col","msg"}] in order.
# with --serve [idle_seconds] it answers one json line per request line, and exits
# when stdin closes or when no request arrives for idle_seconds.
import json
import os
import sys
import threading


def check(name, text):
    try:
        compile(text, name, 'exec', dont_inherit=True)
        return {'ok': True}
    except SyntaxError as e:
        return {'ok': False, 'line': e.lineno or 0, 'col': e.offset or 0, 'msg': e.msg or 'syntax error'}
    except Exception as e:
        return {'ok': False, 'line': 0, 'col': 0, 'msg': str(e) or e.__class__.__name__}


def answer(raw):
    files = json.loads(raw.decode('utf-8'))
    return json.dumps([check(f['name'], f['text']) for f in files])


def serve(idle):
    timer = None

    def arm():
        nonlocal timer
        if idle > 0:
            timer = threading.Timer(idle, lambda: os._exit(0))
            timer.daemon = True
            timer.start()

    arm()
    for line in sys.stdin.buffer:
        if timer is not None:
            timer.cancel()
        if line.strip():
            sys.stdout.write(answer(line) + '\n')
            sys.stdout.flush()
        arm()


def main():
    if '--serve' in sys.argv:
        at = sys.argv.index('--serve') + 1
        idle = float(sys.argv[at]) if at < len(sys.argv) else 0
        serve(idle)
        return
    sys.stdout.write(answer(sys.stdin.buffer.read()))


main()
