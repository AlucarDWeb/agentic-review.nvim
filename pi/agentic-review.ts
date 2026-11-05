// Connects an interactive pi session to agentic-review.nvim through two JSON-lines files in $AGENTIC_REVIEW_DIR:
// Neovim appends requests to `inbox`, and this extension appends each finished reply to `outbox`.
import * as fs from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Request = { id?: string; type?: string; prompt?: string; model?: string; full_shell?: boolean };
type Run = { id: string | null; fullShell: boolean; texts: string[] };

export default function (pi: ExtensionAPI) {
	const dir = process.env.AGENTIC_REVIEW_DIR;
	if (!dir) return;
	const inbox = `${dir}/inbox`;
	const outbox = `${dir}/outbox`;
	const queue: Request[] = [];
	let offset = 0;
	let partial = "";
	let sending = false;
	let pending: Request | null = null;
	let run: Run | null = null;
	let current: any;
	let timer: ReturnType<typeof setInterval> | undefined;

	function read() {
		let data = "";
		try {
			const fd = fs.openSync(inbox, "r");
			const size = fs.fstatSync(fd).size;
			if (size > offset) {
				const buf = Buffer.alloc(size - offset);
				fs.readSync(fd, buf, 0, buf.length, offset);
				offset = size;
				data = buf.toString("utf8");
			}
			fs.closeSync(fd);
		} catch {
			return;
		}
		const lines = (partial + data).split("\n");
		partial = lines.pop() ?? "";
		for (const line of lines) {
			try {
				const req = JSON.parse(line) as Request;
				if (req.type === "abort") {
					queue.length = 0;
					if (current && !current.isIdle()) current.abort();
				} else {
					queue.push(req);
				}
			} catch {
				// A line that is not JSON is not a request.
			}
		}
	}

	async function next(ctx: any) {
		if (sending || !ctx.isIdle() || queue.length === 0) return;
		const req = queue.shift() as Request;
		sending = true;
		try {
			const [provider, ...rest] = (req.model ?? "").split("/");
			const model = rest.length > 0 ? ctx.modelRegistry.find(provider, rest.join("/")) : undefined;
			if (model && (ctx.model?.provider !== model.provider || ctx.model?.id !== model.id)) {
				await pi.setModel(model);
			}
			pending = req;
			pi.sendUserMessage(req.prompt ?? "", { expandPromptTemplates: true });
		} finally {
			sending = false;
		}
	}

	pi.on("session_start", async (_event, ctx) => {
		current = ctx;
		if (timer) clearInterval(timer);
		timer = setInterval(() => {
			read();
			void next(current);
		}, 200);
		timer.unref?.();
	});

	pi.on("session_shutdown", async () => {
		if (timer) clearInterval(timer);
	});

	pi.on("input", async (event, ctx) => {
		current = ctx;
		if (event.streamingBehavior) return { action: "continue" };
		if (event.source === "extension" && pending) {
			run = { id: pending.id ?? null, fullShell: pending.full_shell === true, texts: [] };
			pending = null;
		} else if (event.source === "interactive") {
			run = { id: null, fullShell: true, texts: [] };
		}
		return { action: "continue" };
	});

	pi.on("tool_call", async (event) => {
		if (event.toolName === "bash" && run && run.id !== null && !run.fullShell) {
			return {
				block: true,
				reason: "Bash is off for requests from Neovim other than the whole-change review. Use read, grep, find and ls.",
			};
		}
		return undefined;
	});

	pi.on("message_end", async (event) => {
		const message: any = event.message;
		if (!run || message.role !== "assistant") return undefined;
		const text = (message.content ?? [])
			.filter((part: any) => part.type === "text")
			.map((part: any) => part.text)
			.join("");
		if (text) run.texts.push(text);
		return undefined;
	});

	pi.on("agent_settled", async (event, ctx) => {
		current = ctx;
		if (run) {
			fs.appendFileSync(outbox, JSON.stringify({ id: run.id, text: run.texts.join("\n\n"), aborted: event.aborted }) + "\n");
			run = null;
		}
		void next(ctx);
	});
}
