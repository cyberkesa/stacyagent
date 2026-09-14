"use strict";
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
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.RuntimeClient = exports.IPCError = exports.MAX_FRAME_SIZE = exports.STACYAGENT_IPC_PROTOCOL_VERSION = void 0;
exports.stableIDForCanonicalPath = stableIDForCanonicalPath;
exports.canonicalPath = canonicalPath;
exports.socketPathFor = socketPathFor;
exports.unwrapPayload = unwrapPayload;
exports.normalizeEventPayload = normalizeEventPayload;
exports.ensureRuntime = ensureRuntime;
const net = __importStar(require("net"));
const fs = __importStar(require("fs"));
const os = __importStar(require("os"));
const path = __importStar(require("path"));
const crypto = __importStar(require("crypto"));
const child_process_1 = require("child_process");
exports.STACYAGENT_IPC_PROTOCOL_VERSION = 1;
exports.MAX_FRAME_SIZE = 8 * 1024 * 1024;
/** FNV-1a 64-bit, lowercase zero-padded hex — mirrors WorkspaceIdentity. */
function stableIDForCanonicalPath(canonicalPath) {
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
function canonicalPath(p) {
    return path.normalize(fs.realpathSync(p));
}
function socketPathFor(workspacePath) {
    const id = stableIDForCanonicalPath(canonicalPath(workspacePath));
    return path.join(os.homedir(), '.stacyagent', 'run', `${id}.sock`);
}
function newRequestID() {
    return crypto.randomUUID().toUpperCase();
}
/**
 * Swift synthesized enum encoding (mirrors StacyAgentIPC on the wire):
 * - single unlabeled value -> {"case": {"_0": value}}
 * - labeled value(s)       -> {"case": {"label": value, ...}}
 * - void                   -> {"case": {}}
 */
/** Inverse of the Swift enum encoding above. */
function unwrapPayload(payload) {
    const keys = Object.keys(payload);
    const caseName = keys[0] ?? 'unknown';
    const inner = payload[caseName];
    if (inner !== null && typeof inner === 'object' && !Array.isArray(inner)) {
        const innerKeys = Object.keys(inner);
        if (innerKeys.length === 1 && innerKeys[0] === '_0') {
            return { caseName, value: inner['_0'] };
        }
    }
    return { caseName, value: inner };
}
const SCALAR_EVENT_CASES = {
    taskStarted: 'text',
    generationStarted: 'label'
};
/** Normalize one raw event payload object to the typed union shape. */
function normalizeEventPayload(raw) {
    const { caseName, value } = unwrapPayload(raw);
    if (caseName in SCALAR_EVENT_CASES && typeof value === 'string') {
        return { [caseName]: { [SCALAR_EVENT_CASES[caseName]]: value } };
    }
    return { [caseName]: value };
}
class IPCError extends Error {
    code;
    constructor(code, message) {
        super(`${code}: ${message}`);
        this.code = code;
        this.name = 'IPCError';
    }
}
exports.IPCError = IPCError;
const REQUEST_TIMEOUT_MS = 10 * 60 * 1000;
class RuntimeClient {
    workspacePath;
    workspaceID;
    socketPath;
    socket = null;
    buffer = Buffer.alloc(0);
    pending = new Map();
    queue = Promise.resolve();
    eventHandler;
    state = 'DISCONNECTED';
    constructor(workspacePath, eventHandler = null) {
        this.workspacePath = canonicalPath(workspacePath);
        this.workspaceID = stableIDForCanonicalPath(this.workspacePath);
        this.socketPath = socketPathFor(workspacePath);
        this.eventHandler = eventHandler;
    }
    setEventHandler(handler) {
        this.eventHandler = handler;
    }
    async connect(clientName = 'stacyagent-workbench') {
        this.state = 'CONNECTING';
        try {
            await new Promise((resolve, reject) => {
                const socket = net.createConnection(this.socketPath);
                const onError = (error) => {
                    socket.destroy();
                    reject(error);
                };
                socket.once('error', onError);
                socket.once('connect', () => {
                    socket.removeListener('error', onError);
                    socket.on('error', () => this.handleDisconnect());
                    socket.on('close', () => this.handleDisconnect());
                    socket.on('data', (chunk) => this.handleData(chunk));
                    this.socket = socket;
                    resolve();
                });
            });
            const response = await this.perform('handshake', {
                handshake: { _0: { clientName, supportedVersion: exports.STACYAGENT_IPC_PROTOCOL_VERSION } }
            });
            const { value } = unwrapPayload(response.payload);
            const payload = value;
            if (!payload?.accepted) {
                throw new IPCError('handshake_rejected', 'runtime rejected handshake');
            }
            this.state = 'CONNECTED';
        }
        catch (error) {
            this.state = 'ERROR';
            this.close();
            throw error;
        }
    }
    /** Serializes requests like the Swift requestLock. */
    enqueue(work) {
        const next = this.queue.then(work, work);
        this.queue = next.then(() => undefined, () => undefined);
        return next;
    }
    async perform(kind, payload) {
        return this.enqueue(async () => {
            const socket = this.socket;
            if (!socket || socket.destroyed) {
                throw new IPCError('disconnected', 'runtime disconnected');
            }
            const requestID = newRequestID();
            const envelope = {
                protocolVersion: exports.STACYAGENT_IPC_PROTOCOL_VERSION,
                requestID,
                workspaceID: this.workspaceID,
                kind,
                payload
            };
            const body = Buffer.from(JSON.stringify(envelope), 'utf8');
            if (body.length > exports.MAX_FRAME_SIZE || body.length === 0) {
                throw new IPCError('invalidPayload', 'frame size out of range');
            }
            const header = Buffer.alloc(4);
            header.writeUInt32BE(body.length, 0);
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    this.pending.delete(requestID);
                    reject(new IPCError('timeout', 'runtime request timed out'));
                }, REQUEST_TIMEOUT_MS);
                this.pending.set(requestID, { resolve, reject, timer });
                socket.write(Buffer.concat([header, body]), (error) => {
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
    handleData(chunk) {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        while (this.buffer.length >= 4) {
            const size = this.buffer.readUInt32BE(0);
            if (size === 0 || size > exports.MAX_FRAME_SIZE) {
                this.handleDisconnect();
                return;
            }
            if (this.buffer.length < 4 + size) {
                return;
            }
            const body = this.buffer.subarray(4, 4 + size);
            this.buffer = this.buffer.subarray(4 + size);
            let envelope;
            try {
                envelope = JSON.parse(body.toString('utf8'));
            }
            catch {
                continue;
            }
            this.dispatch(envelope);
        }
    }
    dispatch(envelope) {
        if (envelope.kind === 'event') {
            const handler = this.eventHandler;
            if (handler) {
                try {
                    const { value } = unwrapPayload(envelope.payload);
                    const event = value;
                    handler({
                        sequence: Number(event.sequence ?? 0),
                        requestID: event.requestID ?? null,
                        taskID: event.taskID ?? null,
                        payload: normalizeEventPayload(event.payload)
                    });
                }
                catch {
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
            const error = value ?? {};
            pending.reject(new IPCError(error.code ?? 'remote', error.message ?? 'remote error'));
            return;
        }
        pending.resolve(envelope);
    }
    handleDisconnect() {
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
    close() {
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
    static responseSnapshot(envelope) {
        const { value } = unwrapPayload(envelope.payload);
        const response = value;
        return response?.snapshot ?? undefined;
    }
    async openWorkspace() {
        const response = await this.perform('openWorkspace', {
            openWorkspace: { _0: { canonicalPath: this.workspacePath } }
        });
        return RuntimeClient.responseSnapshot(response);
    }
    async submit(text) {
        const response = await this.perform('submitTurn', { submitTurn: { _0: { text } } });
        return RuntimeClient.responseSnapshot(response);
    }
    async snapshot() {
        const response = await this.perform('getSnapshot', { getSnapshot: {} });
        const snapshot = RuntimeClient.responseSnapshot(response);
        if (!snapshot) {
            throw new IPCError('invalidPayload', 'snapshot response');
        }
        return snapshot;
    }
    async ping() {
        const response = await this.perform('ping', { ping: {} });
        if (response.kind !== 'pong') {
            throw new IPCError('invalidPayload', 'pong');
        }
    }
    /** Cancellation uses a side connection so it never queues behind submit. */
    async cancel(taskID) {
        const side = new RuntimeClient(this.workspacePath);
        await side.connect('stacyagent-workbench-cancel');
        try {
            const response = await side.perform('cancelTask', { cancelTask: { _0: { taskID } } });
            const { value } = unwrapPayload(response.payload);
            const payload = value;
            if (!payload?.accepted) {
                throw new IPCError('invalidPayload', 'cancel rejected');
            }
        }
        finally {
            side.close();
        }
    }
    async shutdown() {
        try {
            await this.perform('shutdown', { shutdown: {} });
        }
        finally {
            this.close();
        }
    }
    async reconnect(clientName = 'stacyagent-workbench') {
        this.close();
        await this.connect(clientName);
        return this.snapshot();
    }
}
exports.RuntimeClient = RuntimeClient;
/** Mirror of RuntimeProcess.ensureRunning: probe, spawn runtime, poll. */
async function ensureRuntime(workspacePath, options) {
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
                try {
                    (0, child_process_1.execSync)(`kill -9 ${pid}`);
                }
                catch { /* ignore */ }
                await waitForSocketClose(sockPath, 5000);
                return spawnRuntime(options, workspacePath);
            }
        }
        return null;
    }
    catch {
        probe.close();
    }
    return spawnRuntime(options, workspacePath);
}
function getPIDForSocket(sockPath) {
    try {
        const out = (0, child_process_1.execSync)(`lsof -i UNIX:${sockPath} -t 2>/dev/null`).toString().trim();
        const pid = parseInt(out, 10);
        return isNaN(pid) ? null : pid;
    }
    catch {
        return null;
    }
}
function getCommandLine(pid) {
    try {
        return (0, child_process_1.execSync)(`ps -p ${pid} -o command= 2>/dev/null`).toString().trim();
    }
    catch {
        return null;
    }
}
async function waitForSocketClose(sockPath, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        try {
            await new Promise((resolve, reject) => {
                const socket = net.createConnection(sockPath);
                socket.once('connect', () => { socket.destroy(); reject(new Error('socket still open')); });
                socket.once('error', () => { socket.destroy(); resolve(); });
            });
            return;
        }
        catch {
            await new Promise(resolve => setTimeout(resolve, 50));
        }
    }
}
async function spawnRuntime(options, workspacePath) {
    const args = [canonicalPath(workspacePath), ...(options.extraArgs ?? [])];
    const child = (0, child_process_1.spawn)(options.binaryPath, args, {
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
        }
        catch {
            client.close();
        }
        if (Date.now() > deadline) {
            child.kill('SIGKILL');
            throw new IPCError('timeout', 'stacyagent-runtime did not become ready');
        }
        await new Promise(resolve => setTimeout(resolve, pollInterval));
    }
}
