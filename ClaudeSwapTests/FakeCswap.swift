//
//  FakeCswap.swift
//  ClaudeSwapTests
//
//  A scripted stand-in for the `cswap` CLI (upstream v0.26.0 behaviour),
//  written into a throwaway temp directory. Tests never run the real cswap,
//  launchctl or touch real account data.
//

import Foundation
@testable import ClaudeSwap

struct FakeCall: Equatable {
    var argv: [String]
    var stdin: String
}

final class FakeCswap: @unchecked Sendable {
    let dir: URL
    let url: URL
    private let scenarioURL: URL

    static let python = "/usr/bin/python3"

    init(version: String = "cswap 0.26.0", accounts: [[String: Any]]? = nil, active: Int = 1) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-cswap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let py = dir.appendingPathComponent("fake.py")
        try Self.script.write(to: py, atomically: true, encoding: .utf8)
        url = dir.appendingPathComponent("cswap")
        try "#!/bin/sh\nexec \(Self.python) -I \"\(py.path)\" \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scenarioURL = dir.appendingPathComponent("scenario.json")
        try setScenario([
            "version": version,
            "schema": 1,
            "active": active,
            "accounts": accounts ?? [Self.account(1), Self.account(2)],
            "config": [
                ["key": "autoswitch.threshold", "value": 95.0, "isSet": true],
            ],
            "fail": [String: Any](),
            "sleep": [String: Any](),
            "listDelay": 0,
        ])
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    static func account(_ number: Int, active: Bool = false) -> [String: Any] {
        [
            "number": number,
            "email": "user\(number)@example.com",
            "organizationName": "Example Org",
            "organizationUuid": "org-\(number)",
            "active": active,
            "usageStatus": "ok",
            "usage": [
                "fiveHour": ["pct": 10.0, "resetsAt": "2026-07-22T19:19:59Z"],
                "sevenDay": ["pct": 5.0, "resetsAt": "2026-07-28T19:59:59Z"],
            ],
        ]
    }

    // MARK: Scenario

    func scenario() throws -> [String: Any] {
        let data = try Data(contentsOf: scenarioURL)
        return fatalObject(try JSONSerialization.jsonObject(with: data))
    }

    func setScenario(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: scenarioURL)
    }

    func update(_ change: (inout [String: Any]) -> Void) throws {
        var current = try scenario()
        change(&current)
        try setScenario(current)
    }

    /// `key` is the argv prefix (e.g. "alias", "config set autoswitch.cooldownSeconds").
    func fail(_ key: String, exit: Int = 1, stdout: String = "", stderr: String = "") throws {
        try update { s in
            var table = s["fail"] as? [String: Any] ?? [:]
            table[key] = ["exit": exit, "stdout": stdout, "stderr": stderr]
            s["fail"] = table
        }
    }

    func sleep(_ key: String, seconds: Double) throws {
        try update { s in
            var table = s["sleep"] as? [String: Any] ?? [:]
            table[key] = seconds
            s["sleep"] = table
        }
    }

    func set(_ key: String, _ value: Any) throws {
        try update { $0[key] = value }
    }

    // MARK: Observations

    func calls() -> [FakeCall] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("calls.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let argv = obj["argv"] as? [String] else { return nil }
            return FakeCall(argv: argv, stdin: obj["stdin"] as? String ?? "")
        }
    }

    func calls(startingWith command: String) -> [FakeCall] {
        calls().filter { $0.argv.first == command }
    }

    var overlaps: [String] {
        (try? String(contentsOf: dir.appendingPathComponent("overlap.log"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    // MARK: Client

    func makeClient(
        timeouts: CswapCLIClient.Timeouts = .init(
            probe: .seconds(10), read: .seconds(10), mutation: .seconds(10)
        ),
        automation: AutoSwitchDaemonService? = nil,
        policy: CLICompatibilityPolicy = .builtIn
    ) -> CswapCLIClient {
        CswapCLIClient(
            cswapURL: url,
            runner: ProcessRunner(killGracePeriod: .milliseconds(300)),
            policy: policy,
            automation: automation,
            baseEnvironment: ["PATH": "/usr/bin:/bin"],
            timeouts: timeouts
        )
    }

    // MARK: Script

    private static let script = ##"""
import sys, os, json, time, signal

d = os.path.dirname(os.path.abspath(__file__))
SC = os.path.join(d, "scenario.json")
argv = sys.argv[1:]
lock = os.path.join(d, "busy.lock")
locked = False

def cleanup():
    global locked
    if locked:
        try:
            os.rmdir(lock)
        except OSError:
            pass
        locked = False

def on_term(sig, frm):
    cleanup()
    sys.exit(143)

signal.signal(signal.SIGTERM, on_term)

try:
    os.mkdir(lock)
    locked = True
except FileExistsError:
    with open(os.path.join(d, "overlap.log"), "a") as f:
        f.write("OVERLAP " + json.dumps(argv) + "\n")

data = sys.stdin.read()
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": argv, "stdin": data}) + "\n")

def load():
    with open(SC) as f:
        return json.load(f)

def save(s):
    tmp = SC + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, SC)

def lookup(table):
    for n in (3, 2, 1):
        k = " ".join(argv[:n])
        if k in table:
            return table[k]
    return None

def finish(code=0):
    sys.stdout.flush()
    sys.stderr.flush()
    cleanup()
    sys.exit(code)

def next_free(s):
    used = set(a["number"] for a in s["accounts"])
    n = 1
    while n in used:
        n += 1
    return n

def slot_arg(s):
    if "--slot" in argv:
        return int(argv[argv.index("--slot") + 1])
    return next_free(s)

s = load()
cmd = argv[0] if argv else ""
lines = data.split("\n")
secret = lines[0] if lines else ""

delay = lookup(s.get("sleep", {}))
if delay is None and cmd == "list":
    delay = s.get("listDelay", 0)
if delay:
    time.sleep(delay)

spec = lookup(s.get("fail", {}))
if spec is not None:
    sys.stdout.write(spec.get("stdout", ""))
    sys.stderr.write(spec.get("stderr", "").replace("{token}", secret))
    finish(spec.get("exit", 1))

def account_for(n, email=None, alias=None):
    a = {
        "number": n,
        "email": email or ("user%d@example.com" % n),
        "organizationName": "Example Org",
        "organizationUuid": "org-%d" % n,
        "active": False,
        "usageStatus": "ok",
        "usage": {"fiveHour": {"pct": 1.0, "resetsAt": "2026-07-22T19:19:59Z"},
                  "sevenDay": {"pct": 1.0, "resetsAt": "2026-07-28T19:59:59Z"}},
    }
    if alias:
        a["alias"] = alias
    return a

def place(s, slot, account, answer):
    if any(a["number"] == slot for a in s["accounts"]):
        if answer.strip().lower() != "y":
            print("Cancelled")
            finish(0)
        s["accounts"] = [a for a in s["accounts"] if a["number"] != slot]
    s["accounts"].append(account)
    s["accounts"].sort(key=lambda a: a["number"])
    save(s)
    print("Added account %d" % slot)

if cmd == "--version":
    print(s["version"])
elif cmd == "list":
    accts = [dict(a, active=(a["number"] == s["active"])) for a in s["accounts"]]
    print(json.dumps({"schemaVersion": s["schema"], "activeAccountNumber": s["active"], "accounts": accts}))
elif cmd == "config" and argv[1:2] == ["list"]:
    print(json.dumps({"schemaVersion": 1, "settings": s["config"]}))
elif cmd == "config" and argv[1:2] == ["set"]:
    key, value = argv[2], argv[3]
    s["config"] = [c for c in s["config"] if c["key"] != key] + [{"key": key, "value": value, "isSet": True}]
    save(s)
    print("Set %s" % key)
elif cmd == "status":
    print(json.dumps({"schemaVersion": 1, "active": s.get("statusActive", {"email": "user1@example.com", "organizationName": "Example Org", "managed": True, "number": 1})}))
elif cmd == "switch":
    ids = [a["number"] for a in s["accounts"]]
    if len(argv) > 1 and argv[1] != "--json":
        s["active"] = int(argv[1])
    else:
        i = ids.index(s["active"]) if s["active"] in ids else -1
        s["active"] = ids[(i + 1) % len(ids)]
    save(s)
    print(json.dumps({"schemaVersion": 1, "ok": True}))
elif cmd == "add-token":
    slot = slot_arg(s)
    answer = lines[1] if len(lines) > 1 else ""
    place(s, slot, account_for(slot, "token%d@example.com" % slot), answer)
elif cmd == "add":
    slot = slot_arg(s)
    alias = argv[argv.index("--alias") + 1] if "--alias" in argv else None
    place(s, slot, account_for(slot, "current@example.com", alias), secret)
elif cmd == "alias":
    n = int(argv[1])
    for a in s["accounts"]:
        if a["number"] == n:
            if argv[2:3] == ["--unset"]:
                a.pop("alias", None)
            else:
                a["alias"] = argv[2]
    save(s)
    print("ok")
elif cmd == "remove":
    if secret.strip().lower() != "y":
        print("Cancelled")
        finish(0)
    s["accounts"] = [a for a in s["accounts"] if str(a["number"]) != argv[1]]
    save(s)
    print("Removed")
elif cmd in ("enable", "disable"):
    print("ok")
elif cmd == "export":
    if not s.get("noExportFile"):
        with open(argv[1], "w") as f:
            f.write("{}")
    print("Exported")
elif cmd == "import":
    sys.stdout.write(s.get("importOutput", ""))
else:
    sys.stderr.write("usage: cswap [-h] ...\ncswap: error: invalid choice: %r\n" % cmd)
    finish(2)
finish(0)
"""##
}

private func fatalObject(_ any: Any) -> [String: Any] { any as? [String: Any] ?? [:] }
