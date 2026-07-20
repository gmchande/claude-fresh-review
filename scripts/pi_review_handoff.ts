import { renameSync, rmSync, writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type AssistantLike = {
	role?: string;
	content?: unknown;
	stopReason?: string;
	errorMessage?: string;
};

const handoffPath = process.env.PI_REVIEW_HANDOFF_PATH?.trim();
const doneMarkerPath = process.env.PI_REVIEW_DONE_MARKER_PATH?.trim();

function extractAssistantText(message: AssistantLike | undefined): string {
	if (!message || message.role !== "assistant" || !Array.isArray(message.content)) return "";

	return message.content
		.filter((block): block is { type: "text"; text: string } => {
			if (!block || typeof block !== "object") return false;
			const candidate = block as { type?: unknown; text?: unknown };
			return candidate.type === "text" && typeof candidate.text === "string";
		})
		.map((block) => block.text)
		.join("\n")
		.trim();
}

function turnStatus(message: AssistantLike | undefined): number {
	if (!message) return 1;
	if (message.stopReason === "aborted") return 130;
	return message.stopReason === "stop" && extractAssistantText(message) ? 0 : 1;
}

function atomicWrite(path: string, content: string): void {
	const temporaryPath = `${path}.${process.pid}.tmp`;
	writeFileSync(temporaryPath, content, { encoding: "utf8", mode: 0o600 });
	renameSync(temporaryPath, path);
}

function clearArtifacts(): void {
	if (doneMarkerPath) rmSync(doneMarkerPath, { force: true });
	if (handoffPath) rmSync(handoffPath, { force: true });
}

export default function reviewHandoff(pi: ExtensionAPI): void {
	let lastAssistant: AssistantLike | undefined;

	pi.on("agent_start", () => {
		lastAssistant = undefined;
		clearArtifacts();
	});

	pi.on("agent_end", (event) => {
		const messages = event.messages as AssistantLike[];
		const assistant = [...messages].reverse().find((message) => message.role === "assistant");
		if (assistant) lastAssistant = assistant;
	});

	pi.on("agent_settled", () => {
		if (!handoffPath || !doneMarkerPath) return;

		const status = turnStatus(lastAssistant);
		const text = extractAssistantText(lastAssistant);
		let handoff = text;

		if (status === 130) {
			handoff = "Pi review turn interrupted; the interactive session remains open for follow-up instructions.";
			if (text) handoff += `\n\nPartial assistant output:\n${text}`;
		} else if (status !== 0) {
			const reason = lastAssistant?.errorMessage?.trim() || `Pi review turn failed with stop reason ${lastAssistant?.stopReason || "unknown"}.`;
			handoff = reason;
			if (text && text !== reason) handoff += `\n\nPartial assistant output:\n${text}`;
		}

		atomicWrite(handoffPath, `${handoff || "Pi review turn ended without a final text response."}\n`);
		atomicWrite(doneMarkerPath, `${status}\n`);
	});
}
