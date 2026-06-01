#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const headlessBinary =
	process.env.GHOSTTY_CLAUDE_HEADLESS_BIN ?? path.join(homedir(), 'ghostty-claude-headless', 'zig-out', 'bin', 'ghostty-claude-headless');
const claudeExecutable = process.env.CLAUDE_PATH ?? path.join(homedir(), '.local', 'bin', 'claude');
const ASK_CLAUDE_IDLE_TIMEOUT_MS = 8 * 60 * 1000;
const ASK_CLAUDE_MAX_TIMEOUT_MS = 30 * 60 * 1000;
const ASK_CLAUDE_PROCESS_TIMEOUT_MS = ASK_CLAUDE_MAX_TIMEOUT_MS + 60 * 1000;
const ASK_CLAUDE_TRANSCRIPT_TIMEOUT_MS = 3 * 1000;

const tool = {
	name: 'ask_claude_ghostty',
	description:
		'Ask the local Claude Code CLI a prompt through a Ghostty/libghostty-backed headless terminal and return the final assistant text from Claude\'s JSONL transcript.',
	inputSchema: {
		type: 'object',
		properties: {
			prompt: {
				type: 'string',
				description: 'The prompt to send to the local claude executable.',
			},
			cwd: {
				type: 'string',
				description: 'Optional working directory for Claude. Defaults to the Codex agent process working directory.',
			},
		},
		required: ['prompt'],
		additionalProperties: false,
	},
};

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
	buffer += chunk;
	for (;;) {
		const newline = buffer.indexOf('\n');
		if (newline === -1) return;
		const line = buffer.slice(0, newline).trim();
		buffer = buffer.slice(newline + 1);
		if (!line) continue;
		handleLine(line).catch((error) => {
			console.error(error);
		});
	}
});

async function handleLine(line) {
	let request;
	try {
		request = JSON.parse(line);
	} catch (error) {
		sendError(null, -32700, `Parse error: ${errorMessage(error)}`);
		return;
	}

	if (!request || typeof request !== 'object') {
		sendError(null, -32600, 'Invalid request.');
		return;
	}

	if (request.id === undefined || request.id === null) return;

	try {
		const result = await dispatch(request);
		send({ jsonrpc: '2.0', id: request.id, result });
	} catch (error) {
		sendError(request.id, error.code ?? -32603, errorMessage(error));
	}
}

async function dispatch(request) {
	switch (request.method) {
		case 'initialize':
			return {
				protocolVersion: request.params?.protocolVersion ?? '2024-11-05',
				capabilities: { tools: {} },
				serverInfo: { name: 'ask-claude-ghostty', version: '0.1.0' },
			};
		case 'ping':
			return {};
		case 'tools/list':
			return { tools: [tool] };
		case 'tools/call':
			return callTool(request.params ?? {});
		default: {
			const error = new Error(`Method not found: ${request.method}`);
			error.code = -32601;
			throw error;
		}
	}
}

async function callTool(params) {
	if (params.name !== tool.name) {
		return { content: [{ type: 'text', text: `Unknown tool: ${params.name}` }], isError: true };
	}

	const args = params.arguments ?? params.input ?? {};
	const prompt = typeof args.prompt === 'string' ? args.prompt : '';
	if (!prompt.trim()) return { content: [{ type: 'text', text: 'Missing prompt.' }], isError: true };

	const cwd = typeof args.cwd === 'string' && args.cwd.trim() ? args.cwd : process.cwd();
	try {
		const text = await runGhosttyClaudePrompt(prompt, cwd);
		return { content: [{ type: 'text', text }], isError: false };
	} catch (error) {
		return { content: [{ type: 'text', text: errorMessage(error) }], isError: true };
	}
}

async function runGhosttyClaudePrompt(prompt, cwd) {
	if (!existsSync(headlessBinary)) {
		throw new Error(`ghostty-claude-headless binary not found at ${headlessBinary}. Build it or set GHOSTTY_CLAUDE_HEADLESS_BIN.`);
	}

	const claude = existsSync(claudeExecutable) ? claudeExecutable : 'claude';
	const result = await spawnWithInput({
		command: headlessBinary,
		args: [
			'--cwd',
			cwd,
			'--claude',
			claude,
			'--max-timeout-ms',
			String(ASK_CLAUDE_MAX_TIMEOUT_MS),
			'--idle-timeout-ms',
			String(ASK_CLAUDE_IDLE_TIMEOUT_MS),
			'--transcript-timeout-ms',
			String(ASK_CLAUDE_TRANSCRIPT_TIMEOUT_MS),
		],
		cwd,
		input: prompt,
		timeoutMs: ASK_CLAUDE_PROCESS_TIMEOUT_MS,
	});

	if (result.exitCode !== 0) {
		throw new Error(result.stderr || `ask_claude_ghostty failed with exit code ${result.exitCode}.`);
	}

	return result.stdout.trimEnd();
}

function spawnWithInput(options) {
	return new Promise((resolve, reject) => {
		const child = spawn(options.command, options.args, {
			cwd: options.cwd,
			env: standaloneTerminalEnv(options.cwd),
			stdio: ['pipe', 'pipe', 'pipe'],
		});

		let stdout = '';
		let stderr = '';
		let settled = false;

		const timeout = setTimeout(() => {
			settled = true;
			child.kill('SIGTERM');
			reject(new Error(`ask_claude_ghostty timed out after ${options.timeoutMs}ms.`));
		}, options.timeoutMs);

		child.stdout.setEncoding('utf8');
		child.stderr.setEncoding('utf8');

		child.stdout.on('data', (chunk) => {
			stdout += chunk;
		});

		child.stderr.on('data', (chunk) => {
			stderr += chunk;
		});

		child.on('error', (error) => {
			if (settled) return;
			settled = true;
			clearTimeout(timeout);
			reject(error);
		});

		child.on('close', (exitCode) => {
			if (settled) return;
			settled = true;
			clearTimeout(timeout);
			resolve({ exitCode, stdout, stderr });
		});

		child.stdin.end(options.input);
	});
}

function standaloneTerminalEnv(cwd) {
	const home = process.env.HOME ?? homedir();
	const env = {
		HOME: home,
		PWD: cwd,
		PATH: terminalPath(home),
		TERM: 'xterm-ghostty',
		COLORTERM: 'truecolor',
		TERM_PROGRAM: 'ghostty',
		TERM_PROGRAM_VERSION: '1.3.2-dev',
		GHOSTTY_SHELL_FEATURES: 'cursor:blink,path,ssh-env,ssh-terminfo,sudo,title',
	};

	copyEnv(env, 'USER');
	copyEnv(env, 'LOGNAME');
	copyEnv(env, 'SHELL');
	copyEnv(env, 'TMPDIR');
	copyEnv(env, 'LANG');
	copyEnv(env, 'LC_ALL');
	copyEnv(env, 'LC_CTYPE');
	copyEnv(env, 'LC_MESSAGES');
	copyEnv(env, 'SSH_AUTH_SOCK');

	return env;
}

function copyEnv(target, name) {
	const value = process.env[name];
	if (value) target[name] = value;
}

function terminalPath(home) {
	return [path.join(home, '.local', 'bin'), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':');
}

function send(message) {
	process.stdout.write(`${JSON.stringify(message)}\n`);
}

function sendError(id, code, message) {
	send({ jsonrpc: '2.0', id, error: { code, message } });
}

function errorMessage(error) {
	return error instanceof Error ? error.message : String(error);
}
