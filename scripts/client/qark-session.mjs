import { spawn } from "node:child_process";
import { once } from "node:events";
import readline from "node:readline";

export class QarkSession {
  constructor(qarkBinOrOptions, workspaceRoot, options = {}) {
    if (typeof qarkBinOrOptions === "object" && qarkBinOrOptions !== null) {
      options = qarkBinOrOptions;
      workspaceRoot = options.root || options.workspaceRoot;
      qarkBinOrOptions = options.bin || options.qarkBin || "qark";
    }
    const qarkBin = qarkBinOrOptions;
    const extraArgs = Array.isArray(options.args) ? options.args : [];
    this.defaultTimeoutMs = options.timeoutMs ?? 30000;
    this.maxStderrBytes = options.maxStderrBytes ?? 8192;
    this.maxPending = options.maxPending ?? 1024;
    this.stderrBuf = "";
    this.closed = false;
    this.exitError = null;
    this.nextId = 1;
    this.pending = new Map();
    this._writeChain = Promise.resolve();

    const isNodeHost =
      /(^|[\\/])node(\.exe)?$/i.test(String(qarkBin)) &&
      extraArgs.length > 0 &&
      /\.(m|c)?js$/i.test(String(extraArgs[0]));
    const spawnArgs = isNodeHost
      ? [extraArgs[0], "--headless", "--stdio", "--root", workspaceRoot, ...extraArgs.slice(1)]
      : ["--headless", "--stdio", "--root", workspaceRoot, ...extraArgs];

    this.proc = spawn(qarkBin, spawnArgs, { stdio: ["pipe", "pipe", "pipe"] });

    this.proc.stdin.on("error", () => {
      // Handled via write callback and process exit/error listeners.
    });

    this.proc.stderr.setEncoding("utf8");
    this.proc.stderr.on("data", (chunk) => {
      this.stderrBuf += chunk;
      if (this.stderrBuf.length > this.maxStderrBytes) {
        this.stderrBuf = this.stderrBuf.slice(-this.maxStderrBytes);
      }
    });

    this.rl = readline.createInterface({ input: this.proc.stdout });
    this.rl.on("line", (line) => {
      if (!line.trim()) return;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (err) {
        const parseErr = new Error(`Malformed JSON from Qark worker: ${err.message}`);
        parseErr.code = "QARK_BAD_JSON";
        this._failAll(parseErr);
        return;
      }
      if (
        msg === null ||
        typeof msg !== "object" ||
        Array.isArray(msg) ||
        (typeof msg.id !== "number" && typeof msg.id !== "string") ||
        typeof msg.ok !== "boolean"
      ) {
        const protoErr = new Error("Malformed protocol envelope from Qark worker");
        protoErr.code = "QARK_BAD_PROTOCOL";
        this._failAll(protoErr);
        return;
      }
      const entry = this.pending.get(msg.id);
      if (entry) {
        this.pending.delete(msg.id);
        clearTimeout(entry.timer);
        entry.resolve(msg);
      }
    });

    this.proc.on("error", (err) => {
      const procErr = new Error(`Qark worker process error: ${err.message}`);
      procErr.code = "QARK_PROCESS_ERROR";
      this._failAll(procErr);
    });

    this.proc.on("exit", (code, signal) => {
      const finishExit = () => {
        const detail = this.stderrBuf.trim()
          ? ` (stderr: ${this.stderrBuf.trim()})`
          : "";
        const exitErr = new Error(
          `Qark worker exited before replying (code=${code}, signal=${signal})${detail}`
        );
        exitErr.code = "QARK_PROCESS_EXITED";
        this._failAll(exitErr);
      };
      const t = setTimeout(finishExit, 50);
      t.unref?.();
      this.rl.once("close", () => {
        clearTimeout(t);
        finishExit();
      });
    });

    this.proc.on("close", (code, signal) => {
      setImmediate(() => {
        const detail = this.stderrBuf.trim()
          ? ` (stderr: ${this.stderrBuf.trim()})`
          : "";
        const closeErr = new Error(
          `Qark worker stream closed (code=${code}, signal=${signal})${detail}`
        );
        closeErr.code = "QARK_PROCESS_EXITED";
        this._failAll(closeErr);
      });
    });
  }

  _failAll(err) {
    if (!this.exitError) {
      this.exitError = err;
    }
    this.closed = true;
    for (const [id, entry] of this.pending.entries()) {
      this.pending.delete(id);
      clearTimeout(entry.timer);
      entry.reject(this.exitError);
    }
  }

  async request(op, args = {}, timeoutMs = this.defaultTimeoutMs) {
    return this.call(op, args, timeoutMs);
  }

  async info(timeoutMs = this.defaultTimeoutMs) {
    const res = await this.call("session.info", {}, timeoutMs);
    return res.result || res;
  }

  async call(op, args = {}, timeoutMs = this.defaultTimeoutMs) {
    if (this.closed || this.exitError) {
      const closedErr = this.exitError || new Error("QarkSession is closed");
      if (!closedErr.code) closedErr.code = "QARK_SESSION_CLOSED";
      throw closedErr;
    }
    if (this.pending.size >= this.maxPending) {
      const queueErr = new Error(`QarkSession pending queue limit (${this.maxPending}) exceeded`);
      queueErr.code = "QARK_QUEUE_FULL";
      throw queueErr;
    }
    const id = this.nextId++;
    const payload = JSON.stringify({ id, op, args }) + "\n";

    return new Promise((resolve, reject) => {
      const timer =
        timeoutMs > 0
          ? setTimeout(() => {
              this.pending.delete(id);
              const timeoutErr = new Error(
                `Qark request #${id} (${op}) timed out after ${timeoutMs}ms`
              );
              timeoutErr.code = "QARK_TIMEOUT";
              timeoutErr.outcomeUnknown = true;
              reject(timeoutErr);
            }, timeoutMs)
          : null;

      this.pending.set(id, { resolve, reject, timer });

      this._writeChain = this._writeChain
        .then(async () => {
          if (!this.pending.has(id) || this.closed) return;
          const flushed = this.proc.stdin.write(payload, "utf8", (writeErr) => {
            if (writeErr && this.pending.has(id)) {
              this.pending.delete(id);
              clearTimeout(timer);
              const err = new Error(`Failed to write to Qark worker stdin: ${writeErr.message}`);
              err.code = "QARK_WRITE_ERROR";
              reject(err);
            }
          });
          if (!flushed && !this.closed && this.proc.exitCode === null) {
            await Promise.race([
              once(this.proc.stdin, "drain").catch(() => {}),
              once(this.proc, "exit").catch(() => {}),
            ]);
          }
        })
        .catch((err) => {
          if (this.pending.has(id)) {
            this.pending.delete(id);
            clearTimeout(timer);
            reject(err);
          }
        });
    });
  }

  async close(timeoutMs = 2000) {
    this.closed = true;
    const closedErr = new Error("QarkSession closed by caller");
    closedErr.code = "QARK_SESSION_CLOSED";
    for (const [id, entry] of this.pending.entries()) {
      this.pending.delete(id);
      clearTimeout(entry.timer);
      entry.reject(closedErr);
    }
    if (this.proc.exitCode !== null || this.proc.signalCode !== null) {
      this.rl.close();
      return;
    }
    const exitPromise = once(this.proc, "exit").catch(() => {});
    try {
      this.proc.stdin.end();
    } catch {}

    const waitMs = Math.max(1, Number(timeoutMs) || 2000);
    let timer;
    await Promise.race([
      exitPromise,
      new Promise((resolve) => {
        timer = setTimeout(resolve, waitMs);
      }),
    ]);
    clearTimeout(timer);

    if (this.proc.exitCode === null && this.proc.signalCode === null) {
      try {
        this.proc.kill("SIGTERM");
      } catch {}
      const graceMs = Math.min(200, Math.max(25, Math.floor(waitMs / 2)));
      let graceTimer;
      await Promise.race([
        exitPromise,
        new Promise((resolve) => {
          graceTimer = setTimeout(resolve, graceMs);
        }),
      ]);
      clearTimeout(graceTimer);
    }

    if (this.proc.exitCode === null && this.proc.signalCode === null) {
      try {
        this.proc.kill("SIGKILL");
      } catch {}
      await exitPromise;
    }

    this.rl.close();
  }
}
