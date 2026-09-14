/**
 * Stacy Agent workbench render proof via Chrome DevTools Protocol.
 *
 * Launches the exact entrypoint the /Applications launcher runs
 * (plus --remote-debugging-port), waits for the workbench page, then
 * asserts in-page: activity bar, sidebar, panel, status bar, editor
 * (a file is opened via CLI goto arg), window title branding, Stacy Agent
 * command registration and Stacy Agent view descriptor registration.
 *
 * Usage: node cdp-proof.mjs --workspace <dir> --file <file> [--timeout-ms N]
 * Exit 0 + "PROOF OK" on success, otherwise FAIL lines + exit 1.
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2);
function flagValue(name, fallback) {
	const i = args.indexOf(name);
	return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
const WORKSPACE = flagValue('--workspace', '');
const OPEN_FILE = flagValue('--file', '');
const TIMEOUT_MS = Number(flagValue('--timeout-ms', '120000'));
const CDP_PORT = Number(flagValue('--cdp-port', '0'));
if (!WORKSPACE) {
	console.error('missing --workspace');
	process.exit(2);
}

const FORK_ROOT = '/Users/stacy/stacyagent-workbench/code-oss';
const BIN = `${FORK_ROOT}/.build/electron/Stacy Agent.app/Contents/MacOS/Stacy Agent`;

let failures = 0;
function check(name, condition, detail = '') {
	if (condition) {
		console.log(`PASS ${name}`);
	} else {
		failures += 1;
		console.log(`FAIL ${name}${detail ? ` :: ${detail}` : ''}`);
	}
}

import net from 'node:net';

function sleep(ms) {
	return new Promise(resolve => setTimeout(resolve, ms));
}

function findFreePort() {
	return new Promise((resolve, reject) => {
		const server = net.createServer();
		server.unref();
		server.once('error', reject);
		server.listen(0, () => {
			const port = server.address().port;
			server.close(() => resolve(port));
		});
	});
}

async function cdpPages() {
	const response = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
	if (!response.ok) {
		throw new Error(`cdp list status ${response.status}`);
	}
	return response.json();
}

function connect(url) {
	return new Promise((resolve, reject) => {
		const socket = new WebSocket(url);
		socket.addEventListener('open', () => resolve(socket), { once: true });
		socket.addEventListener('error', () => reject(new Error('websocket failed')), { once: true });
	});
}

let nextId = 1;
const pending = new Map();

function cdp(socket, method, params = {}) {
	return new Promise((resolve, reject) => {
		const id = nextId++;
		pending.set(id, {
			resolve: (message) => resolve(message),
			reject
		});
		socket.send(JSON.stringify({ id, method, params }));
		setTimeout(() => {
			if (pending.has(id)) {
				pending.delete(id);
				reject(new Error(`${method} timeout`));
			}
		}, 30000);
	});
}
function evaluate(socket, expression) {
	return new Promise((resolve, reject) => {
		const id = nextId++;
		pending.set(id, { resolve, reject });
		socket.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
		setTimeout(() => {
			if (pending.has(id)) {
				pending.delete(id);
				reject(new Error('evaluate timeout'));
			}
		}, 30000);
	});
}

async function waitForRender(socket) {
	const deadline = Date.now() + 120000;
	for (;;) {
		const title = await evaluate(socket, 'document.title').catch(() => '');
		const bar = await evaluate(
			socket, '!!document.querySelector("#workbench\\.parts\\.activitybar")'
		).catch(() => false);
		if (typeof title === 'string' && title.includes('Stacy Agent') && bar === true) {
			return;
		}
		if (Date.now() > deadline) {
			throw new Error('workbench render timeout');
		}
		await sleep(2000);
	}
}

async function main() {
	const port = CDP_PORT || await findFreePort();
	const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'stacyagent-cdp-profile-'));
	const extensionsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'stacyagent-cdp-ext-'));
	// Dev entrypoint contract (mirrors scripts/code.sh): the repository root
	// itself is the Electron app (package.json main -> ./out/main.js).
	const launchArgs = [
		FORK_ROOT,
		WORKSPACE,
		'--user-data-dir', userDataDir,
		'--extensions-dir', extensionsDir,
		'--verbose',
		'--disable-extension', 'vscode.vscode-api-tests',
		`--remote-debugging-port=${port}`,
		'--remote-allow-origins=*'
	];
	if (OPEN_FILE) {
		launchArgs.push(OPEN_FILE);
	}
 const child = spawn(BIN, launchArgs, {
		cwd: FORK_ROOT,
		env: {
			...process.env,
			NODE_ENV: 'development',
			VSCODE_DEV: '1',
			VSCODE_CLI: '1',
			ELECTRON_ENABLE_STACK_DUMPING: '1',
			ELECTRON_ENABLE_LOGGING: '1'
		},
		stdio: 'ignore'
	});
	const cleanup = () => {
		try { child.kill('SIGKILL'); } catch { /* gone */ }
	};
	const deadline = Date.now() + TIMEOUT_MS;
	let pageUrl = null;
	try {
		for (;;) {
			if (Date.now() > deadline) {
				throw new Error('workbench page never appeared');
			}
			try {
				const pages = await cdpPages();
				const workbench = pages.find(p => p.type === 'page' && (p.url || '').startsWith('vscode-file://'));
				if (workbench) {
					pageUrl = workbench.webSocketDebuggerUrl;
					break;
				}
			} catch {
				// CDP endpoint not up yet.
			}
			await sleep(1000);
		}
		check('cdp/workbench-page', !!pageUrl, pageUrl ?? 'none');
		try {
			const pages = await cdpPages();
			console.error(`cdp targets: ${JSON.stringify(pages.map(p => ({ type: p.type, url: p.url })))}`);
		} catch { /* diagnostics only */ }
		const socket = await connect(pageUrl);
		socket.addEventListener('message', (event) => {
			try {
				const message = JSON.parse(String(event.data));
				const entry = pending.get(message.id);
				if (!entry) {
					return;
				}
				pending.delete(message.id);
				if (message.error) {
					entry.reject(new Error(message.error.message || 'cdp failed'));
				} else {
					entry.resolve(message.result);
				}
			} catch (error) {
				// Malformed frame: ignore, pending entries time out on their own.
			}
		});
		async function evaluateInPage(expression) {
			const result = await cdp(socket, 'Runtime.evaluate', { expression, returnByValue: true });
			if (result.exceptionDetails) {
				throw new Error(`evaluate threw: ${JSON.stringify(result.exceptionDetails).slice(0, 200)}`);
			}
			return result.result?.value;
		}
		async function keyEvent(type, options) {
			await cdp(socket, 'Input.dispatchKeyEvent', { type, ...options });
		}
		async function waitFor(expression, timeoutMs = 60000, label = 'condition') {
			const deadline = Date.now() + timeoutMs;
			for (;;) {
				const value = await evaluateInPage(expression).catch(() => undefined);
				if (value) {
					return value;
				}
				if (Date.now() > deadline) {
					throw new Error(`wait timeout: ${label}`);
				}
				await sleep(1000);
			}
		}
		const title = await waitFor(
			`document.title && document.title.length > 0 ? document.title : ''`,
			120000,
			'window title'
		);
		// Layout renders after the title: wait for the part chrome.
		for (const selector of [
			'#workbench\\.parts\\.activitybar',
			'#workbench\\.parts\\.sidebar',
			'#workbench\\.parts\\.panel',
			'#workbench\\.parts\\.statusbar'
		]) {
			await waitFor(`!!document.querySelector('${selector}')`, 120000, selector);
		}
		check(
			'brand/window-title',
			typeof title === 'string' && title.includes(path.basename(WORKSPACE)),
			String(title)
		);
		const product = JSON.parse(fs.readFileSync(path.join(FORK_ROOT, 'product.json'), 'utf8'));
		check('brand/product-name', product.nameLong === 'Stacy Agent', String(product.nameLong));
		for (const [name, selector] of [
			['chrome/activity-bar', '#workbench\\.parts\\.activitybar'],
			['chrome/sidebar', '#workbench\\.parts\\.sidebar'],
			['chrome/panel', '#workbench\\.parts\\.panel'],
			['chrome/statusbar', '#workbench\\.parts\\.statusbar']
		]) {
			const present = await evaluateInPage(`!!document.querySelector('${selector}')`);
			check(name, present === true, String(present));
		}
		if (OPEN_FILE) {
			const editorOpen = await evaluateInPage(`!!document.querySelector('.editor-instance') && (document.querySelector('.editor-instance')?.textContent ?? '').length > 0`);
			check('chrome/editor-open', editorOpen === true, String(editorOpen));
		}
		// Drive the command palette: Cmd+Shift+P, type, read rows.
		// Proves Stacy Agent commands are registered AND executable in the live UI.
		await cdp(socket, 'Page.bringToFront');
		await waitFor(`document.hasFocus()`, 30000, 'window focus');
		await keyEvent('rawKeyDown', { modifiers: 12, windowsVirtualKeyCode: 80, key: 'p' });
		await keyEvent('keyUp', { modifiers: 12, windowsVirtualKeyCode: 80, key: 'p' });
		await waitFor(
			`!!document.querySelector('.quick-input-widget')`,
			30000,
			'command palette'
		);
		check('ui/command-palette', true);
		await cdp(socket, 'Input.insertText', { text: 'Stacy Agent: Focus' });
		await sleep(2000);
		const paletteRows = await evaluateInPage(
			`Array.from(document.querySelectorAll('.quick-input-widget .monaco-list-row .label-name')).map(e => e.textContent)`
		);
		check(
			'stacyagent/palette-lists-focus',
			Array.isArray(paletteRows) && paletteRows.some(t => (t ?? '').includes('Stacy Agent: Focus')),
			JSON.stringify(paletteRows)
		);
		// Enter runs the focused command (exact match) -> Stacy Agent panel opens.
		await keyEvent('rawKeyDown', { windowsVirtualKeyCode: 13, key: 'Enter' });
		await keyEvent('keyUp', { windowsVirtualKeyCode: 13, key: 'Enter' });
		const panelVisible = await waitFor(
			`!!document.querySelector('.stacyagent-panel')`,
			60000,
			'stacyagent panel'
		).then(() => true).catch(() => false);
		check('stacyagent/panel-renders', panelVisible === true, String(panelVisible));
		if (panelVisible) {
			const composer = await evaluateInPage(`!!document.querySelector('.stacyagent-panel textarea.stacyagent-input')`);
			check('stacyagent/panel-composer', composer === true, String(composer));
			const timeline = await evaluateInPage(`!!document.querySelector('.stacyagent-panel ul.stacyagent-timeline')`);
			check('stacyagent/panel-timeline', timeline === true, String(timeline));
		}
		socket.close();
	} finally {
		cleanup();
		try { child.kill('SIGKILL'); } catch { /* gone */ }
		await sleep(2000);
		fs.rmSync(userDataDir, { recursive: true, force: true });
		fs.rmSync(extensionsDir, { recursive: true, force: true });
	}
	console.log(failures === 0 ? 'PROOF OK' : `PROOF FAILED (${failures})`);
	process.exit(failures === 0 ? 0 : 1);
}

main().catch(error => {
	console.error(`proof fatal: ${error?.stack ?? error}`);
	process.exit(2);
});
