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
    this.stderrBuf = "";
    this.closed = false;
    this.exitError = null;
    this.nextId = 1;
    this.pending = new Map();

    this.proc = spawn(
      qarkBin,
      ["--headless", "--stdio", "--root", workspaceRoot, ...extraArgs],
      { stdio: ["pipe", "pipe", "pipe"] }
    );

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
      const detail = this.stderrBuf.trim()
        ? ` (stderr: ${this.stderrBuf.trim()})`
        : "";
      const exitErr = new Error(
        `Qark worker exited before replying (code=${code}, signal=${signal})${detail}`
      );
      exitErr.code = "QARK_PROCESS_EXITED";
      this._failAll(exitErr);
    });

    this.proc.on("close", (code, signal) => {
      const detail = this.stderrBuf.trim()
        ? ` (stderr: ${this.stderrBuf.trim()})`
        : "";
      const closeErr = new Error(
        `Qark worker stream closed (code=${code}, signal=${signal})${detail}`
      );
      closeErr.code = "QARK_PROCESS_EXITED";
      this._failAll(closeErr);
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
    const id = this.nextId++;
    const payload = JSON.stringify({ id, op, args }) + "\n";

    return new Promise((resolve, reject) => {
      const timer =
        timeoutMs > 0
          ? setTimeout(() => {
              this.pending.delete(id);
              reject(
                new Error(
                  `Qark request #${id} (${op}) timed out after ${timeoutMs}ms`
                )
              );
            }, timeoutMs)
          : null;

      this.pending.set(id, { resolve, reject, timer });

      try {
        const flushed = this.proc.stdin.write(payload, "utf8", (writeErr) => {
          if (writeErr && this.pending.has(id)) {
            this.pending.delete(id);
            clearTimeout(timer);
            reject(
              new Error(`Failed to write to Qark worker stdin: ${writeErr.message}`)
            );
          }
        });
        if (!flushed) {
          once(this.proc.stdin, "drain").catch(() => {});
        }
      } catch (err) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(err);
      }
    });
  }

  async close(timeoutMs = 2000) {
    this.closed = true;
    if (this.proc.exitCode !== null || this.proc.killed) {
      this.rl.close();
      return;
    }
    const exitPromise = once(this.proc, "exit").catch(() => {});
    try {
      this.proc.stdin.end();
    } catch {}
    let killTimer;
    const timeoutPromise = new Promise((resolve) => {
      killTimer = setTimeout(() => {
        try {
          this.proc.kill();
        } catch {}
        resolve();
      }, timeoutMs);
    });
    await Promise.race([exitPromise, timeoutPromise]);
    clearTimeout(killTimer);
    this.rl.close();
  }
}
