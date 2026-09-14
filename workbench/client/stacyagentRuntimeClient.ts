/**
 * Stacy Agent RuntimeClient — canonical TypeScript client for the v0.32 typed IPC.
 *
 * Speaks the exact contract of Sources/StacyAgentIPC (framing: u32 big-endian
 * length + JSON; envelopes: {protocolVersion, requestID, workspaceID,
 * kind, payload}; payloads: single-key {caseName: value} objects, void
 * cases encoded as {}).
 *
 * Zero dependencies, no vscode imports: shared by the Code-OSS workbench
 * contribution and the Node acceptance harness.
 */

import * as net from 'net';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as crypto from 'crypto';
import { spawn, ChildProcess, execSync } from 'child_process';

export const STACYAGENT_IPC_PROTOCOL_VERSION = 1;
export const MAX_FRAME_SIZE = 8 * 1024 * 1024;

export type ConnectionState = 'CONNECTING' | 'CONNECTED' | 'DISCONNECTED' | 'ERROR';

export interface RuntimeTelemetrySnapshot {
	modelCalls: number;
	deterministicActions: number;
	toolResults: number;
	contextTokens: number;
}

export interface ArtifactRevisionSummary {
	path: string;
	revision: string;
}

export interface RuntimeSnapshot {
	workspaceID: string;
	canonicalWorkspacePath: string;
	runtimeStatus: string;
	activeTaskID: string | null;
	recentTaskSummary: string | null;
	taskPhase: string | null;
	taskOutcome: string | null;
	artifactRevisions: ArtifactRevisionSummary[];
	unresolvedRequirements: string[];
	lastFailure: string | null;
	telemetry: RuntimeTelemetrySnapshot;
}

export type RuntimeEventPayload =
	| { modelLoading: Record<string, never> }
	| { modelReady: Record<string, never> }
	| { taskStarted: { text: string } }
	| { taskState: { taskID: string; phase: string } }
	| { generationStarted: { label: string } }
	| { generationProgress: { label: string; seconds: number; chunks: number } }
	| { generationFinished: Record<string, never> }
	| { toolStarted: { name: string } }
	| { toolFinished: { name: string; ok: boolean; detail: string; durationSeconds: number } }
	| { assistant: { text: string } }
	| { notice: { text: string } }
	| { warning: { text: string } }
	| { completed: { elapsedSeconds: number; outputTokens: number } }
	| { telemetry: { name: string; detail: string } };

export interface RuntimeEvent {
	sequence: number;
	requestID: string | null;
	taskID: string | null;
	payload: RuntimeEventPayload;
}

export type EventHandler = (event: RuntimeEvent) => void;

/** FNV-1a 64-bit, lowercase zero-padded hex — mirrors WorkspaceIdentity. */
export function stableIDForCanonicalPath(canonicalPath: string): string {
	let hash = 14695981039346656037n;
	const prime = 1099511628211n;
	const mask = 0xffffffffffffffffn;
	for (const byte of Buffer.from(canonicalPath, 'utf8')) {
		hash ^= BigInt(byte);
		hash = (hash * prime) & mask;
	}
	return hash.toString(16).padStart(16, '0');
}

/** Canonical path: resolve symlinks + normalize (mirrors standardizedFileURL). */
export function canonicalPath(p: string): string {
	return path.normalize(fs.realpathSync(p));
}

export function socketPathFor(workspacePath: string): string {
	const id = stableIDForCanonicalPath(canonicalPath(workspacePath));
	return path.join(os.homedir(), '.stacyagent', 'run', `${id}.sock`);
}

function newRequestID(): string {
	return crypto.randomUUID().toUpperCase();
}

/**
 * Swift synthesized enum encoding (mirrors StacyAgentIPC on the wire):
 * - single unlabeled value -> {"case": {"_0": value}}
 * - labeled value(s)       -> {"case": {"label": value, ...}}
 * - void                   -> {"case": {}}
 */
/** Inverse of the Swift enum encoding above. */
export function unwrapPayload(payload: Record<string, unknown>): { caseName: string; value: unknown } {
	const keys = Object.keys(payload);
	const caseName = keys[0] ?? 'unknown';
	const inner = payload[caseName] as Record<string, unknown> | unknown;
	if (inner !== null && typeof inner === 'object' && !Array.isArray(inner)) {
		const innerKeys = Object.keys(inner);
		if (innerKeys.length === 1 && innerKeys[0] === '_0') {
			return { caseName, value: (inner as Record<string, unknown>)['_0'] };
		}
	}
	return { caseName, value: inner };
}

const SCALAR_EVENT_CASES: Record<string, string> = {
	taskStarted: 'text',
	generationStarted: 'label'
};

/** Normalize one raw event payload object to the typed union shape. */
export function normalizeEventPayload(raw: Record<string, unknown>): RuntimeEventPayload {
	const { caseName, value } = unwrapPayload(raw);
	if (caseName in SCALAR_EVENT_CASES && typeof value === 'string') {
		return { [caseName]: { [SCALAR_EVENT_CASES[caseName]]: value } } as unknown as RuntimeEventPayload;
	}
	return { [caseName]: value } as unknown as RuntimeEventPayload;
}

export class IPCError extends Error {
	constructor(public code: string, message: string) {
		super(`${code}: ${message}`);
		this.name = 'IPCError';
	}
}

interface PendingRequest {
	resolve: (envelope: Envelope) => void;
	reject: (error: Error) => void;
	timer: ReturnType<typeof setTimeout>;
}

interface Envelope {
	protocolVersion: number;
	requestID: string;
	workspaceID: string;
	kind: string;
	payload: Record<string, unknown>;
}

const REQUEST_TIMEOUT_MS = 10 * 60 * 1000;

export class RuntimeClient {
	readonly workspacePath: string;
	readonly workspaceID: string;
	readonly socketPath: string;
	private socket: net.Socket | null = null;
	private buffer = Buffer.alloc(0);
	private pending = new Map<string, PendingRequest>();
	private queue: Promise<unknown> = Promise.resolve();
	private eventHandler: EventHandler | null;
	state: ConnectionState = 'DISCONNECTED';

	constructor(workspacePath: string, eventHandler: EventHandler | null = null) {
		this.workspacePath = canonicalPath(workspacePath);
		this.workspaceID = stableIDForCanonicalPath(this.workspacePath);
		this.socketPath = socketPathFor(workspacePath);
		this.eventHandler = eventHandler;
	}

	setEventHandler(handler: EventHandler | null): void {
		this.eventHandler = handler;
	}

	async connect(clientName = 'stacyagent-workbench'): Promise<void> {
		this.state = 'CONNECTING';
		try {
			await new Promise<void>((resolve, reject) => {
				const socket = net.createConnection(this.socketPath);
				const onError = (error: Error) => {
					socket.destroy();
					reject(error);
				};
				socket.once('error', onError);
				socket.once('connect', () => {
					socket.removeListener('error', onError);
					socket.on('error', () => this.handleDisconnect());
					socket.on('close', () => this.handleDisconnect());
					socket.on('data', (chunk: Buffer) => this.handleData(chunk));
					this.socket = socket;
					resolve();
				});
			});
			const response = await this.perform('handshake', {
				handshake: { _0: { clientName, supportedVersion: STACYAGENT_IPC_PROTOCOL_VERSION } }
			});
			const { value } = unwrapPayload(response.payload);
			const payload = value as { accepted?: boolean } | undefined;
			if (!payload?.accepted) {
				throw new IPCError('handshake_rejected', 'runtime rejected handshake');
			}
			this.state = 'CONNECTED';
		} catch (error) {
			this.state = 'ERROR';
			this.close();
			throw error;
		}
	}

	/** Serializes requests like the Swift requestLock. */
	private enqueue<T>(work: () => Promise<T>): Promise<T> {
		const next = this.queue.then(work, work);
		this.queue = next.then(() => undefined, () => undefined);
		return next;
	}

	private async perform(kind: string, payload: Record<string, unknown>): Promise<Envelope> {
		return this.enqueue(async () => {
			const socket = this.socket;
			if (!socket || socket.destroyed) {
				throw new IPCError('disconnected', 'runtime disconnected');
			}
			const requestID = newRequestID();
			const envelope: Envelope = {
				protocolVersion: STACYAGENT_IPC_PROTOCOL_VERSION,
				requestID,
				workspaceID: this.workspaceID,
				kind,
				payload
			};
			const body = Buffer.from(JSON.stringify(envelope), 'utf8');
			if (body.length > MAX_FRAME_SIZE || body.length === 0) {
				throw new IPCError('invalidPayload', 'frame size out of range');
			}
			const header = Buffer.alloc(4);
			header.writeUInt32BE(body.length, 0);
			return new Promise<Envelope>((resolve, reject) => {
				const timer = setTimeout(() => {
					this.pending.delete(requestID);
					reject(new IPCError('timeout', 'runtime request timed out'));
				}, REQUEST_TIMEOUT_MS);
				this.pending.set(requestID, { resolve, reject, timer });
				socket.write(Buffer.concat([header, body]), (error?: Error | null) => {
					if (error) {
						const pending = this.pending.get(requestID);
						if (pending) {
							this.pending.delete(requestID);
							clearTimeout(pending.timer);
							reject(error);
						}
					}
				});
			});
		});
	}

	private handleData(chunk: Buffer): void {
		this.buffer = Buffer.concat([this.buffer, chunk]);
		while (this.buffer.length >= 4) {
			const size = this.buffer.readUInt32BE(0);
			if (size === 0 || size > MAX_FRAME_SIZE) {
				this.handleDisconnect();
				return;
			}
			if (this.buffer.length < 4 + size) {
				return;
			}
			const body = this.buffer.subarray(4, 4 + size);
			this.buffer = this.buffer.subarray(4 + size);
			let envelope: Envelope;
			try {
				envelope = JSON.parse(body.toString('utf8')) as Envelope;
			} catch {
				continue;
			}
			this.dispatch(envelope);
		}
	}

	private dispatch(envelope: Envelope): void {
		if (envelope.kind === 'event') {
			const handler = this.eventHandler;
			if (handler) {
				try {
					const { value } = unwrapPayload(envelope.payload);
					const event = value as Partial<RuntimeEvent>;
					handler({
						sequence: Number(event.sequence ?? 0),
						requestID: (event.requestID as string | null) ?? null,
						taskID: (event.taskID as string | null) ?? null,
						payload: normalizeEventPayload(
							event.payload as unknown as Record<string, unknown>
						)
					});
				} catch {
					// Never let UI handlers break the read loop.
				}
			}
			return;
		}
		const pending = this.pending.get(envelope.requestID);
		if (!pending) {
			return;
		}
		this.pending.delete(envelope.requestID);
		clearTimeout(pending.timer);
		if (envelope.kind === 'error') {
			const { value } = unwrapPayload(envelope.payload);
			const error = (value as { code?: string; message?: string }) ?? {};
			pending.reject(new IPCError(error.code ?? 'remote', error.message ?? 'remote error'));
			return;
		}
		pending.resolve(envelope);
	}

	private handleDisconnect(): void {
		if (this.state === 'CONNECTED' || this.state === 'CONNECTING') {
			this.state = 'DISCONNECTED';
		}
		for (const [, pending] of this.pending) {
			clearTimeout(pending.timer);
			pending.reject(new IPCError('disconnected', 'runtime disconnected'));
		}
		this.pending.clear();
		this.buffer = Buffer.alloc(0);
		if (this.socket) {
			this.socket.destroy();
			this.socket = null;
		}
	}

	close(): void {
		if (this.socket) {
			this.socket.destroy();
			this.socket = null;
		}
		for (const [, pending] of this.pending) {
			clearTimeout(pending.timer);
			pending.reject(new IPCError('disconnected', 'client closed'));
		}
		this.pending.clear();
		this.buffer = Buffer.alloc(0);
		this.state = 'DISCONNECTED';
	}

	private static responseSnapshot(envelope: Envelope): RuntimeSnapshot | undefined {
		const { value } = unwrapPayload(envelope.payload);
		const response = value as { snapshot?: RuntimeSnapshot } | undefined;
		return response?.snapshot ?? undefined;
	}

	async openWorkspace(): Promise<RuntimeSnapshot | undefined> {
		const response = await this.perform('openWorkspace', {
			openWorkspace: { _0: { canonicalPath: this.workspacePath } }
		});
		return RuntimeClient.responseSnapshot(response);
	}

	async submit(text: string): Promise<RuntimeSnapshot | undefined> {
		const response = await this.perform('submitTurn', { submitTurn: { _0: { text } } });
		return RuntimeClient.responseSnapshot(response);
	}

	async snapshot(): Promise<RuntimeSnapshot> {
		const response = await this.perform('getSnapshot', { getSnapshot: {} });
		const snapshot = RuntimeClient.responseSnapshot(response);
		if (!snapshot) {
			throw new IPCError('invalidPayload', 'snapshot response');
		}
		return snapshot;
	}

	async ping(): Promise<void> {
		const response = await this.perform('ping', { ping: {} });
		if (response.kind !== 'pong') {
			throw new IPCError('invalidPayload', 'pong');
		}
	}

	/** Cancellation uses a side connection so it never queues behind submit. */
	async cancel(taskID: string): Promise<void> {
		const side = new RuntimeClient(this.workspacePath);
		await side.connect('stacyagent-workbench-cancel');
		try {
			const response = await side.perform('cancelTask', { cancelTask: { _0: { taskID } } });
			const { value } = unwrapPayload(response.payload);
			const payload = value as { accepted?: boolean } | undefined;
			if (!payload?.accepted) {
				throw new IPCError('invalidPayload', 'cancel rejected');
			}
		} finally {
			side.close();
		}
	}

	async shutdown(): Promise<void> {
		try {
			await this.perform('shutdown', { shutdown: {} });
		} finally {
			this.close();
		}
	}

	async reconnect(clientName = 'stacyagent-workbench'): Promise<RuntimeSnapshot> {
		this.close();
		await this.connect(clientName);
		return this.snapshot();
	}
}

export interface SpawnedRuntime {
	process: ChildProcess;
	workspacePath: string;
}

/** Mirror of RuntimeProcess.ensureRunning: probe, spawn runtime, poll. */
export async function ensureRuntime(
	workspacePath: string,
	options: {
		binaryPath: string;
		extraArgs?: string[];
		pollIntervalMs?: number;
		timeoutMs?: number;
	}
): Promise<SpawnedRuntime | null> {
	const probe = new RuntimeClient(workspacePath);
	try {
		await probe.connect('probe');
		probe.close();
		// Socket is listening — validate the runtime binary
		const sockPath = socketPathFor(workspacePath);
		const pid = getPIDForSocket(sockPath);
		if (pid) {
			const cmd = getCommandLine(pid);
			if (cmd && cmd.includes('mlxagent') && !cmd.includes('stacyagent-runtime')) {
				// Old mlxagent on the socket — kill it so stacyagent-runtime can spawn
				try { execSync(`kill -9 ${pid}`); } catch { /* ignore */ }
				await waitForSocketClose(sockPath, 5000);
				return spawnRuntime(options, workspacePath);
			}
		}
		return null;
	} catch {
		probe.close();
	}
	return spawnRuntime(options, workspacePath);
}

function getPIDForSocket(sockPath: string): number | null {
	try {
		const out = execSync(`lsof -i UNIX:${sockPath} -t 2>/dev/null`).toString().trim();
		const pid = parseInt(out, 10);
		return isNaN(pid) ? null : pid;
	} catch {
		return null;
	}
}

function getCommandLine(pid: number): string | null {
	try {
		return execSync(`ps -p ${pid} -o command= 2>/dev/null`).toString().trim();
	} catch {
		return null;
	}
}

async function waitForSocketClose(sockPath: string, timeoutMs: number): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			await new Promise<void>((resolve, reject) => {
				const socket = net.createConnection(sockPath);
				socket.once('connect', () => { socket.destroy(); reject(new Error('socket still open')); });
				socket.once('error', () => { socket.destroy(); resolve(); });
			});
			return;
		} catch {
			await new Promise(resolve => setTimeout(resolve, 50));
		}
	}
}

async function spawnRuntime(options: { binaryPath: string; extraArgs?: string[]; pollIntervalMs?: number; timeoutMs?: number }, workspacePath: string): Promise<SpawnedRuntime | null> {
	const args = [canonicalPath(workspacePath), ...(options.extraArgs ?? [])];
	const child = spawn(options.binaryPath, args, {
		stdio: 'ignore',
		detached: false
	});
	const pollInterval = options.pollIntervalMs ?? 100;
	const deadline = Date.now() + (options.timeoutMs ?? 60000);
	for (;;) {
		const client = new RuntimeClient(workspacePath);
		try {
			await client.connect('startup-probe');
			client.close();
			return { process: child, workspacePath: canonicalPath(workspacePath) };
		} catch {
			client.close();
		}
		if (Date.now() > deadline) {
			child.kill('SIGKILL');
			throw new IPCError('timeout', 'stacyagent-runtime did not become ready');
		}
		await new Promise(resolve => setTimeout(resolve, pollInterval));
	}
}
