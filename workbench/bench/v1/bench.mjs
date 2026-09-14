/**
 * STACY AGENT BENCHMARK V1 (protocol level, fake-model runtime, deterministic).
 *
 * Fixed workspace: workbench/bench/v1/workspace (A/B/C.swift), reset before
 * every run. No architecture changes: reads only the public IPC contract
 * (snapshots + event stream).
 *
 * Usage:
 *   node workbench/bench/v1/bench.mjs --binary .build/debug/stacyagent-runtime [--json]
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
	RuntimeClient,
	ensureRuntime,
	canonicalPath
} from '../../harness/dist/stacyagentRuntimeClient.js';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE = path.join(ROOT, 'workspace');
const args = process.argv.slice(2);
const flagValue = (name, fallback) => {
	const i = args.indexOf(name);
	return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const BINARY = flagValue('--binary', '');
const JSON_ONLY = args.includes('--json');
if (!BINARY) {
	console.error('missing --binary /path/to/stacyagent-runtime');
	process.exit(2);
}

const PRISTINE = {
	'A.swift': `struct UserManager {
    var name: String
    var active: Bool = true
}

let marker = "TODO: document UserManager lifecycle"

func primaryUser() -> UserManager {
    UserManager(name: "Ada")
}
`,
	'B.swift': `let manager = UserManager(name: "Ada")

// BUG: must return the number of users (1), never a negative count.
func userCount() -> Int {
    return -1
}

func managerName() -> String {
    manager.name
}
`,
	'C.swift': `func describe(_ m: UserManager) -> String {
    m.active ? "active user \\(m.name)" : "inactive user \\(m.name)"
}

let summary = describe(UserManager(name: "Grace"))
`
};

function resetWorkspace() {
	for (const [file, content] of Object.entries(PRISTINE)) {
		fs.writeFileSync(path.join(WORKSPACE, file), content);
	}
}

async function killStrayDaemons() {
	try {
		spawnSync('pkill', ['-9', '-f', 'stacyagent-runtime']);
	} catch { /* best effort */ }
	try {
		spawnSync('pkill', ['-9', '-f', `mlxagent.*${WORKSPACE}`]);
	} catch { /* best effort */ }
	await new Promise(r => setTimeout(r, 500));
}

function repoTokens() {
	let chars = 0;
	for (const f of fs.readdirSync(WORKSPACE)) {
		if (f.endsWith('.swift')) {
			chars += fs.readFileSync(path.join(WORKSPACE, f), 'utf8').length;
		}
	}
	return { chars, approxTokens: Math.round(chars / 4) };
}

function parseDetail(detail, keys) {
	const out = {};
	for (const key of keys) {
		const m = new RegExp(`${key}=([^\\s]+)`).exec(detail ?? '');
		if (m) { out[key] = m[1]; }
	}
	return out;
}

async function runTask(client, events, name, text, verify) {
	events.length = 0;
	const before = await client.snapshot();
	const t0 = Date.now();
	const snap = await client.submit(text);
	const wallMs = Date.now() - t0;
	const after = snap ?? await client.snapshot();
	const mine = events.slice();

	const caseNames = mine.map(e => Object.keys(e.payload ?? {})[0] ?? '?');
	const tele = (n) => mine
		.filter(e => e.payload?.telemetry?.name === n)
		.map(e => e.payload.telemetry.detail);
	const first = (n) => tele(n)[0] ?? '';
	const routed = parseDetail(first('computationRouted'), ['strategy', 'modelCalls', 'cacheHit']);
	const finished = parseDetail(first('computationFinished'), ['strategy', 'candidates', 'modelAvoided', 'cacheHit']);
	const bundle = parseDetail(first('contextCompilationFinished'), ['items', 'tokens', 'levels', 'cacheHit']);
	const intel = mine.filter(e => e.payload?.telemetry?.name === 'intelligenceFinished')
		.map(e => e.payload.telemetry.detail);
	const generations = intel.length;
	const outputTokens = mine
		.filter(e => e.payload?.completed)
		.map(e => e.payload.completed.outputTokens ?? 0)
		.reduce((a, b) => a + b, 0);
	const validations = mine
		.filter(e => e.payload?.validationFinished || e.payload?.telemetry?.name === 'validationFinished')
		.map(e => e.payload.validationFinished ?? e.payload.telemetry.detail);
	const assistant = mine.filter(e => e.payload?.assistant).map(e => e.payload.assistant.text ?? '');

	const row = {
		task: name,
		outcome: after?.taskOutcome ?? null,
		wallMs,
		modelCalls: (after?.telemetry?.modelCalls ?? 0) - (before?.telemetry?.modelCalls ?? 0),
		deterministicActions: (after?.telemetry?.deterministicActions ?? 0) - (before?.telemetry?.deterministicActions ?? 0),
		toolResults: (after?.telemetry?.toolResults ?? 0) - (before?.telemetry?.toolResults ?? 0),
		contextTokensDelta: (after?.telemetry?.contextTokens ?? 0) - (before?.telemetry?.contextTokens ?? 0),
		strategy: routed.strategy ?? finished.strategy ?? null,
		routerModelCalls: routed.modelCalls ?? null,
		modelAvoided: finished.modelAvoided ?? null,
		candidates: finished.candidates ?? null,
		intelQueries: intel.length,
		intelDetail: intel.slice(0, 3),
		bundleItems: bundle.items ?? null,
		bundleTokens: bundle.tokens ?? null,
		bundleLevels: bundle.levels ?? null,
		generations,
		outputTokens,
		validations,
		lastFailure: after?.lastFailure ?? null,
		cases: caseNames.join(','),
		assistantPreview: (assistant[0] ?? '').slice(0, 160)
	};
	const check = verify ? verify({ row, workspace: WORKSPACE, fs, path }) : { success: null, note: '' };
	row.success = check.success;
	row.note = check.note ?? '';
	return row;
}

const read = (f) => fs.readFileSync(path.join(WORKSPACE, f), 'utf8');

async function main() {
	resetWorkspace();
	killStrayDaemons();
	await new Promise(r => setTimeout(r, 1000));
	const repo = repoTokens();

	await ensureRuntime(WORKSPACE, {
		binaryPath: BINARY,
		extraArgs: ['--fake-runtime', '--no-mcp']
	});
	const events = [];
	const client = new RuntimeClient(WORKSPACE, e => events.push(e));
	await client.connect('bench-v1');
	await client.openWorkspace();
	await client.snapshot();

	const rows = [];
	rows.push(await runTask(client, events, 'A-exact-search',
		'Find exact string "TODO" in project files.',
		({ row }) => ({
			success: row.outcome === 'completed' && row.modelCalls === 0 && /TODO/.test(row.assistantPreview),
			note: 'literal path; answer must cite the marker'
		})));
	rows.push(await runTask(client, events, 'B-semantic-rename',
		'rename UserManager to AccountManager in A.swift',
		({ row, workspace, fs, path }) => {
			const content = fs.readFileSync(path.join(workspace, 'A.swift'), 'utf8');
			return {
				success: row.outcome === 'completed' && row.modelCalls === 0 && !content.includes('UserManager') && content.includes('AccountManager'),
				note: 'semantic rename; zero model calls'
			};
		}));
	rows.push(await runTask(client, events, 'C-deterministic-navigation',
		'Find "AccountManager" in project files.',
		({ row }) => ({
			success: row.outcome === 'completed' && row.modelCalls === 0 && /AccountManager/.test(row.assistantPreview),
			note: 'literal search path; answer must mention AccountManager'
		})));
	rows.push(await runTask(client, events, 'D-reasoning-bugfix',
		'Fix the userCount bug in B.swift: it returns -1, must return the number of users.',
		({ row }) => ({
			success: row.modelCalls >= 1 && row.generations >= 1,
			note: 'model-routed; fake model authors no edits (documented)'
		})));
	rows.push(await runTask(client, events, 'E-multifile-reasoning',
		'Trace AccountManager usage across A.swift, B.swift and C.swift and propose the plan for a future BillingAccount rename.',
		({ row }) => ({
			success: row.modelCalls >= 1,
			note: 'bundle must stay bounded vs whole repo'
		})));

	client.close();
	const report = {
		workspace: canonicalPath(WORKSPACE),
		repoChars: repo.chars,
		repoApproxTokens: repo.approxTokens,
		binary: BINARY,
		rows
	};
	if (JSON_ONLY) {
		console.log(JSON.stringify(report, null, 1));
	} else {
		const last = rows[rows.length - 1];
		for (const r of rows) {
			console.log(`${r.success ? 'PASS' : 'FAIL'} ${r.task} :: outcome=${r.outcome} wall=${r.wallMs}ms calls=${r.modelCalls} routerCalls=${r.routerModelCalls} strategy=${r.strategy} bundle=${r.bundleItems ?? '?'}items/${r.bundleTokens ?? '?'}tok gens=${r.generations} out=${r.outputTokens}tok valid=${JSON.stringify(r.validations)} :: ${r.note}`);
		}
		console.log(`repo: ${repo.chars} chars (~${repo.approxTokens} tok) :: last bundle tokens=${last.bundleTokens ?? '?'} vs repo ~${repo.approxTokens}`);
	}
}

main().catch(e => { console.error(`bench fatal: ${e?.stack ?? e}`); process.exit(2); });
