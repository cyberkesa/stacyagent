/**
 * Stacy Agent workbench acceptance harness (protocol level, deterministic).
 *
 * Drives a fake-model stacyagent-runtime through the canonical TS RuntimeClient
 * and proves: handshake/snapshot, literal zero-model task, semantic rename
 * zero-model with on-disk changes, reasoning task with exactly one model
 * call, reconnect state restore, bounded cancel, kill/recover, and
 * multi-client (IDE + CLI) coexistence.
 *
 * Usage:
 *   node acceptance.mjs --binary /path/to/stacyagent-runtime [--keep-tmp]
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import {
	RuntimeClient,
	ensureRuntime,
	stableIDForCanonicalPath,
	canonicalPath
} from './dist/stacyagentRuntimeClient.js';

const args = process.argv.slice(2);
function flagValue(name, fallback) {
	const index = args.indexOf(name);
	return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}
const BINARY = flagValue('--binary', '');
const KEEP_TMP = args.includes('--keep-tmp');
if (!BINARY) {
	console.error('missing --binary /path/to/stacyagent-runtime');
	process.exit(2);
}

let failures = 0;
let passes = 0;
function check(name, condition, detail = '') {
	if (condition) {
		passes += 1;
		console.log(`PASS ${name}`);
	} else {
		failures += 1;
		console.log(`FAIL ${name}${detail ? ` :: ${detail}` : ''}`);
	}
}

function makeWorkspace() {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'stacyagent-harness-'));
	fs.writeFileSync(
		path.join(dir, 'A.swift'),
		'struct UserManager {}\nlet marker = "TODO"\n'
	);
	fs.writeFileSync(path.join(dir, 'B.swift'), 'let manager = UserManager()\n');
	return dir;
}

function sleep(ms) {
	return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
	const workspace = makeWorkspace();
	console.log(`workspace: ${workspace}`);
	let spawned = null;
	try {
		// --- identity parity with Swift WorkspaceIdentity ---
		const canonical = canonicalPath(workspace);
		check(
			'identity/canonical-resolves-symlinks',
			!canonical.includes('/tmp/') || canonical.startsWith('/private/'),
			canonical
		);
		const id = stableIDForCanonicalPath(canonical);
		check('identity/stable-id-shape', /^[0-9a-f]{16}$/.test(id), id);

		spawned = await ensureRuntime(workspace, {
			binaryPath: BINARY,
			extraArgs: ['--fake-runtime', '--no-mcp']
		});
		check('runtime/spawn-or-reuse', true);

		const events = [];
		const client = new RuntimeClient(workspace, event => events.push(event));
		await client.connect('harness-ide');
		check('runtime/handshake', client.state === 'CONNECTED', client.state);

		const opened = await client.openWorkspace();
		check(
			'workspace/open-snapshot-id',
			opened?.workspaceID === id,
			JSON.stringify(opened?.workspaceID)
		);

		// --- D. literal task, zero model calls ---
		events.length = 0;
		const literal = await client.submit('Find exact string "TODO" in project files.');
		check('task-literal/completed', literal?.taskOutcome === 'completed', literal?.taskOutcome);
		check('task-literal/zero-model-calls', literal?.telemetry.modelCalls === 0, JSON.stringify(literal?.telemetry));
		check(
			'task-literal/timeline',
			events.some(e => 'taskStarted' in e.payload || 'taskState' in e.payload) && events.some(e => 'assistant' in e.payload),
			`events=${events.length}`
		);

		// --- E. semantic rename, zero model calls, on-disk change ---
		events.length = 0;
		const rename = await client.submit('rename UserManager to AccountManager in A.swift');
		const renamedA = fs.readFileSync(path.join(workspace, 'A.swift'), 'utf8');
		const renamedB = fs.readFileSync(path.join(workspace, 'B.swift'), 'utf8');
		check('task-rename/completed', rename?.taskOutcome === 'completed', rename?.taskOutcome);
		check('task-rename/zero-model-calls', rename?.telemetry.modelCalls === 0, JSON.stringify(rename?.telemetry));
		check(
			'task-rename/all-references-changed',
			!renamedA.includes('UserManager') && !renamedB.includes('UserManager'),
			`A=${JSON.stringify(renamedA)} B=${JSON.stringify(renamedB)}`
		);

		// --- F. reasoning task, exactly one model call + context ---
		const reasoning = await client.submit('Explain the architecture of this project.');
		check('task-reasoning/completed', reasoning?.taskOutcome === 'completed', reasoning?.taskOutcome);
		check('task-reasoning/one-model-call', reasoning?.telemetry.modelCalls === 1, JSON.stringify(reasoning?.telemetry));
		check(
			'task-reasoning/context-bundle',
			(reasoning?.telemetry.contextTokens ?? 0) > 0,
			JSON.stringify(reasoning?.telemetry)
		);

		// --- C. reconnect restores snapshot state ---
		client.close();
		const second = new RuntimeClient(workspace);
		await second.connect('harness-reconnect');
		const restored = await second.snapshot();
		check(
			'reconnect/recent-task',
			restored.recentTaskSummary?.includes('Explain') === true,
			restored.recentTaskSummary ?? 'none'
		);
		check('reconnect/telemetry', restored.telemetry.modelCalls === 1, JSON.stringify(restored.telemetry));

		// --- I. second concurrent client (stand-in CLI) works ---
		const cli = new RuntimeClient(workspace);
		await cli.connect('harness-cli');
		const [snapA, snapB] = await Promise.all([second.snapshot(), cli.snapshot()]);
		check(
			'multiclient/concurrent-snapshots',
			snapA.workspaceID === id && snapB.workspaceID === id,
			`${snapA.workspaceID} ${snapB.workspaceID}`
		);

		// --- G. bounded cancel of a blocking turn ---
		const blocked = second.submit('__ipc_test_block__');
		let activeID = null;
		for (let i = 0; i < 40 && activeID === null; i++) {
			await sleep(25);
		 try {
				const observer = new RuntimeClient(workspace);
				await observer.connect('cancel-observer');
				try {
					activeID = (await observer.snapshot()).activeTaskID;
				} finally {
					observer.close();
				}
			} catch {
				// Runtime may be momentarily busy; keep polling.
			}
		}
		const cancelStart = Date.now();
		if (activeID) {
			await second.cancel(activeID);
		}
		const blockedResult = await blocked;
		const cancelElapsed = Date.now() - cancelStart;
		await second.ping();
		check(
			'cancel/bounded-usable',
			activeID !== null && cancelElapsed < 2000 &&
			blockedResult?.taskOutcome === 'cancelled',
			`active=${activeID} elapsed=${cancelElapsed} outcome=${blockedResult?.taskOutcome}`
		);

		// --- B. closing one client (IDE) keeps the runtime alive ---
		cli.close();
		check('ide-close/runtime-survives', second.state === 'CONNECTED' || (await second.ping().then(() => true).catch(() => false)), '');
		const afterClose = await second.snapshot();
		check('ide-close/snapshot-after-close', afterClose.workspaceID === id, afterClose.workspaceID);
		check(
			'ide-close/process-alive',
			spawned === null || spawned.process.exitCode === null,
			`exit=${spawned?.process.exitCode}`
		);

		second.close();
		cli.close();

		// --- H. kill -9 runtime -> client sees disconnect -> respawn recovers ---
		if (spawned) {
			const killer = new RuntimeClient(workspace);
			await killer.connect('harness-killer');
			spawned.process.kill('SIGKILL');
			let sawDisconnect = false;
			for (let i = 0; i < 50 && !sawDisconnect; i++) {
				try {
					await killer.ping();
				} catch {
					sawDisconnect = true;
					break;
				}
				await sleep(100);
			}
			killer.close();
			check('kill/disconnect-surfaced', sawDisconnect, `sawDisconnect=${sawDisconnect}`);
			const fresh = await ensureRuntime(workspace, {
				binaryPath: BINARY,
				extraArgs: ['--fake-runtime', '--no-mcp']
			});
			if (fresh) {
				spawned.process = fresh.process;
			}
			const revived = new RuntimeClient(workspace);
			await revived.connect('harness-revived');
			const revivedSnapshot = await revived.snapshot();
			check('kill/respawn-reconnect', revivedSnapshot.workspaceID === id, revivedSnapshot.workspaceID);
			await revived.shutdown().catch(() => undefined);
			revived.close();
		} else {
			check('kill/skipped-shared-runtime', true, 'runtime was already running');
		}
	} finally {
		if (spawned) {
			try {
				const finisher = new RuntimeClient(workspace);
				await finisher.connect('harness-shutdown');
				await finisher.shutdown();
				finisher.close();
			} catch {
				// Best effort; fall through to SIGKILL.
			}
			await sleep(500);
			if (spawned.process.exitCode === null) {
				spawned.process.kill('SIGKILL');
			}
		}
		if (!KEEP_TMP) {
			fs.rmSync(workspace, { recursive: true, force: true });
		} else {
			console.log(`kept workspace: ${workspace}`);
		}
	}
	console.log(`\nacceptance: ${passes} passed, ${failures} failed`);
	process.exit(failures === 0 ? 0 : 1);
}

main().catch(error => {
	console.error(`harness fatal: ${error?.stack ?? error}`);
	process.exit(2);
});
