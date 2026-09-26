import Foundation

/// The whole `~/.config/opencode/plugins/koffeelid.js` file: OpenCode has no command hooks, so KoffeeLid
/// installs a plugin instead. The source is the v2 shape (`export default { id, setup(ctx) }` over
/// `ctx.event.subscribe()`; a v1-style plugin fails to load), tested by hand against a real OpenCode 2.0.17
/// server, generated for `hookPath` (the hook binary's absolute path), with `location.shutdown` left out of
/// the forwarded events and no `directory` field anywhere: no path leaves OpenCode. A subagent's events
/// attach to the ROOT top-level session: the plugin walks `state.parents` up to the top (capped at 16 steps,
/// which also guards against a cycle) before writing `parent_id`, so a grandchild's events become helper
/// events of the top session, not of its immediate parent.
public enum OpencodePlugin {
    /// KoffeeLid's plugin id: OpenCode refuses a second plugin whose id is already loaded, so every app of
    /// the family needs its own.
    public static let id = "dev.rubens.koffeelid.opencode"

    /// The whole plugin file's text for `hookPath`. OpenCode loads it by itself, no registration, no trust
    /// step, hot-reloaded within a second of the file changing.
    public static func source(hookPath: String) -> String {
        // JSON-encoded, not pasted in raw: a `"` or a `\` in the path must not break the plugin's own syntax.
        // A JSON string literal is a valid JS one too.
        let command = jsonStringLiteral(hookPath)
        return """
        // KoffeeLid: forwards opencode session lifecycle events to KoffeeLidHook.
        // Installed at ~/.config/opencode/plugins/koffeelid.js by KoffeeLid; opencode 2.x loads it by itself.
        // One small JSON object on the hook's stdin per lifecycle event. It never blocks opencode and never throws.
        import { spawn } from "node:child_process"

        const COMMAND = [\(command), "hook", "opencode"]
        const ID = "\(id)"

        // Every instance of this plugin in one opencode server shares this state. opencode loads a global
        // plugin once per open directory, and every instance receives the events of every directory, so the
        // event id decides which instance forwards.
        const SHARED = Symbol.for(`${ID}:1`)
        const LIMIT = 2048

        const FORWARDED = new Set([
          "session.created",
          "session.forked",
          "session.deleted",
          "session.inbox.enqueued",
          "session.execution.started",
          "session.execution.succeeded",
          "session.execution.failed",
          "session.execution.interrupted",
          "session.tool.called",
          "session.tool.success",
          "session.tool.failed",
          "permission.asked",
          "permission.replied",
          "form.created",
          "form.replied",
          "form.cancelled",
          "session.compaction.started",
          "session.compaction.ended",
          "session.compaction.failed",
        ])

        function shared() {
          const state = globalThis[SHARED]
          if (state) return state
          return (globalThis[SHARED] = { seen: new Set(), tools: new Map(), parents: new Map(), tail: Promise.resolve(), pending: 0 })
        }

        function bounded(collection, key, value) {
          if (collection instanceof Map) collection.set(key, value)
          else collection.add(key)
          if (collection.size > LIMIT) collection.delete(collection.keys().next().value)
        }

        function text(value) {
          return typeof value === "string" && value.length > 0 && value.length <= 200 ? value : undefined
        }

        // The topmost ancestor of `id` reachable through `state.parents` (child id -> its own direct parent
        // id), capped at 16 hops so a cycle cannot loop forever.
        function rootOf(state, id) {
          let current = id
          for (let i = 0; i < 16 && state.parents.has(current); i++) current = state.parents.get(current)
          return current
        }

        function payload(state, event) {
          const data = event.data && typeof event.data === "object" ? event.data : {}
          const type = event.type
          const sessionID = text(data.sessionID) ?? text(data.form?.sessionID)
          const out = { hook_event_name: type, session_id: sessionID ?? null, event_time: event.created, opencode_pid: process.pid }

          if (type === "session.created" && text(data.parentID)) bounded(state.parents, sessionID, data.parentID)
          if (sessionID) {
            const root = rootOf(state, sessionID)
            if (root !== sessionID) out.parent_id = root
          }
          // A deleted session's own link stays: dropping it here would resolve a still-live grandchild's
          // parent_id to the deleted session instead of walking through it to the true root. LIMIT bounds
          // the map, so a link outlives its session only until 2048 newer ones evict it.

          switch (type) {
            case "session.inbox.enqueued":
              if (data.item?.type !== "user") return undefined
              out.delivery = text(data.item.delivery) ?? null
              break
            case "session.execution.succeeded":
              out.status = "succeeded"
              break
            case "session.execution.failed":
              out.status = "failed"
              out.error_name = text(data.error?.type) ?? null
              break
            case "session.execution.interrupted":
              out.status = "interrupted"
              out.reason = text(data.reason) ?? null
              break
            case "session.tool.called":
            case "session.tool.success":
            case "session.tool.failed":
              out.tool_use_id = text(data.id) ?? null
              out.tool_name = state.tools.get(data.id) ?? null
              if (type !== "session.tool.called") state.tools.delete(data.id)
              if (type === "session.tool.failed") out.error_name = text(data.error?.type) ?? null
              break
            case "permission.asked":
              out.permission = text(data.action) ?? null
              break
            case "permission.replied":
              out.status = text(data.reply) ?? null
              break
            case "form.created":
              out.question = data.form?.metadata?.kind === "question"
              break
            case "session.compaction.started":
            case "session.compaction.ended":
            case "session.compaction.failed":
              out.reason = text(data.reason) ?? null
              break
          }
          return out
        }

        // One hook process at a time, in event order, so the journal keeps opencode's order.
        // A hook that hangs holds the queue for at most two seconds; a full queue drops new events.
        function launch(message) {
          return new Promise((resolve) => {
            let settled = false
            const finish = () => {
              if (settled) return
              settled = true
              clearTimeout(timer)
              resolve()
            }
            const timer = setTimeout(finish, 2000)
            try {
              const child = spawn(COMMAND[0], COMMAND.slice(1), { stdio: ["pipe", "ignore", "ignore"], detached: true })
              child.on("error", finish)
              child.on("exit", finish)
              child.stdin.on("error", () => {})
              child.stdin.end(JSON.stringify(message) + "\\n")
              child.unref()
            } catch {
              finish()
            }
          })
        }

        function enqueue(state, message) {
          if (state.pending >= 256) return
          state.pending++
          state.tail = state.tail
            .then(() => launch(message))
            .catch(() => {})
            .then(() => {
              state.pending--
            })
        }

        function handle(event) {
          if (!event || typeof event.type !== "string") return
          const state = shared()
          if (event.type === "session.tool.input.started") {
            if (text(event.data?.id) && text(event.data?.name)) bounded(state.tools, event.data.id, event.data.name)
            return
          }
          if (!FORWARDED.has(event.type)) return
          if (typeof event.id !== "string" || state.seen.has(event.id)) return
          bounded(state.seen, event.id)
          const message = payload(state, event)
          if (message) enqueue(state, message)
        }

        export default {
          id: ID,
          setup(ctx) {
            const controller = new AbortController()
            void (async () => {
              try {
                for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
                  try {
                    handle(event)
                  } catch {}
                }
              } catch {}
            })()
            return () => controller.abort()
          },
        }

        """
    }

    /// `value` as a JSON string literal, valid JS syntax too: quotes, backslashes and control characters
    /// escaped, so a hook path holding any of them cannot break the plugin it is spliced into. Slashes are
    /// left unescaped, so `isOurs`'s marker still matches and the path stays readable.
    private static let stringEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]; return e
    }()
    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? stringEncoder.encode(value), let literal = String(data: data, encoding: .utf8) else {
            return "\"\(value)\""   // JSONEncoder cannot fail encoding a String; never reached.
        }
        return literal
    }

    /// A file is ours when it carries the hook binary's marker and this plugin's id, whatever bundle path
    /// or wording else it holds: `isCurrent` decides whether it also matches byte for byte.
    public static func isOurs(_ text: String) -> Bool {
        text.contains("/Contents/MacOS/KoffeeLidHook") && text.contains(id)
    }

    /// Whether `text` is exactly what `source(hookPath:)` would write today.
    public static func isCurrent(_ text: String, hookPath: String) -> Bool {
        text == source(hookPath: hookPath)
    }
}
