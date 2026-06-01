import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import type { PluginAPI } from '@ampcode/plugin';

const installedHeadlessBinary = '__GHOSTTY_CLAUDE_HEADLESS_BIN__';
const defaultHeadlessBinary = installedHeadlessBinary.startsWith('__')
	? path.join(homedir(), 'ghostty-claude-headless', 'zig-out', 'bin', 'ghostty-claude-headless')
	: installedHeadlessBinary;
const headlessBinary = process.env.GHOSTTY_CLAUDE_HEADLESS_BIN ?? defaultHeadlessBinary;
const claudeExecutable = process.env.CLAUDE_PATH ?? path.join(homedir(), '.local', 'bin', 'claude');
const ASK_CLAUDE_IDLE_TIMEOUT_MS = 8 * 60 * 1000;
const ASK_CLAUDE_MAX_TIMEOUT_MS = 30 * 60 * 1000;
const ASK_CLAUDE_PROCESS_TIMEOUT_MS = ASK_CLAUDE_MAX_TIMEOUT_MS + 60 * 1000;
const ASK_CLAUDE_TRANSCRIPT_TIMEOUT_MS = 3 * 1000;

export default function (amp: PluginAPI) {
	amp.registerTool({
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
					description: 'Optional working directory for Claude. Defaults to Amp\'s current working directory.',
				},
			},
			required: ['prompt'],
		},
		async execute(input, ctx) {
			const prompt = typeof input.prompt === 'string' ? input.prompt : '';
			if (!prompt.trim()) return 'Missing prompt.';

			const cwd = typeof input.cwd === 'string' && input.cwd.trim() ? input.cwd : process.cwd();
			ctx.logger.log(`ask_claude_ghostty prompt length: ${prompt.length}`);
			return runGhosttyClaudePrompt(prompt, cwd);
		},
	});

	amp.logger.log(`ask_claude_ghostty tool registered using ${headlessBinary}`);
}

async function runGhosttyClaudePrompt(prompt: string, cwd: string): Promise<string> {
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

function spawnWithInput(options: {
	command: string;
	args: string[];
	cwd: string;
	input: string;
	timeoutMs: number;
}): Promise<{ exitCode: number | null; stdout: string; stderr: string }> {
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

function standaloneTerminalEnv(cwd: string): NodeJS.ProcessEnv {
	const home = process.env.HOME ?? homedir();
	const env: NodeJS.ProcessEnv = {
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

function copyEnv(target: NodeJS.ProcessEnv, name: string) {
	const value = process.env[name];
	if (value) target[name] = value;
}

function terminalPath(home: string) {
	return [path.join(home, '.local', 'bin'), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':');
}
