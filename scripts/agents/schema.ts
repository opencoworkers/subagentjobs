/**
 * Type-safe sub-agent schema for Claude Code.
 *
 * Mirrors crates/schema/src/agent.rs — Zod edition.
 * Both must stay in sync: same models, same tools, same field names.
 *
 * Generate .claude/agents/*.yaml:
 *   npx ts-node scripts/agents/generate.ts
 *
 * Spec: https://code.claude.com/docs/en/sub-agents
 */

import { z } from 'zod';

// ── Model IDs ──────────────────────────────────────────────────────────────────

export const AgentModel = z.enum([
  'claude-opus-4-8',
  'claude-sonnet-4-6',
  'claude-haiku-4-5-20251001',
]);
export type AgentModel = z.infer<typeof AgentModel>;

// ── Tools ──────────────────────────────────────────────────────────────────────

/**
 * Built-in Claude Code tools.
 * Source of truth: https://claude.com/docs/cowork/3p/configuration#disabledBuiltinTools
 */
export const AgentTool = z.enum([
  'Bash',
  'Read',
  'Write',
  'Edit',
  'Glob',
  'Grep',
  'Task',
  'TaskCreate',
  'TaskUpdate',
  'TaskGet',
  'TaskList',
  'TaskStop',
  'WebFetch',
  'WebSearch',
  'Skill',
  'AskUserQuestion',
  'NotebookEdit',
  'JavaScript',
  'TodoWrite',
  'ToolSearch',
  'SendUserMessage',
]);
export type AgentTool = z.infer<typeof AgentTool>;

// ── Agent config ───────────────────────────────────────────────────────────────

export const AgentConfig = z.object({
  /** Machine-readable identifier → filename: `{name}.yaml`. Lowercase, hyphens only. */
  name: z.string().regex(/^[a-z0-9-]+$/, 'name must be [a-z0-9-]'),

  /**
   * Human + LLM-readable trigger description. Claude reads this to decide
   * whether to delegate. Should include both when-to-use AND when NOT to use.
   */
  description: z.string().min(20, 'description too short — Claude needs specificity to delegate correctly'),

  /** Omit to inherit from the parent session model. */
  model: AgentModel.optional(),

  /** Explicit tool allowlist. Empty = inherit default tool set. Prefer explicit. */
  tools: z.array(AgentTool).default([]),

  /** Max agentic turns. Prevents runaway loops on open-ended tasks. */
  max_turns: z.number().int().positive().optional(),

  /** System prompt injected into the agent's context on every invocation. */
  system_prompt: z.string().min(1, 'system_prompt cannot be empty'),
});
export type AgentConfig = z.infer<typeof AgentConfig>;

// ── Claude Desktop profile ─────────────────────────────────────────────────────

/**
 * claude_desktop_config.json shape (standard Anthropic-backed Claude Desktop).
 *
 * For 3P enterprise config (Bedrock/Vertex/Foundry), see:
 * https://claude.com/docs/cowork/3p/configuration
 */
export const McpServerConfig = z.object({
  command: z.string(),
  args: z.array(z.string()).default([]),
  env: z.record(z.string()).optional(),
});
export type McpServerConfig = z.infer<typeof McpServerConfig>;

export const ClaudeDesktopProfile = z.object({
  /** Profile label — not read by Claude Desktop, used in profiles/switch-profile.sh */
  _profile: z.string(),
  /** MCP servers available in the Code tab. */
  mcpServers: z.record(McpServerConfig).default({}),
  /**
   * 3P enterprise overrides (optional).
   * Only needed when routing inference through Bedrock/Vertex/Foundry.
   * Leave empty for standard claude.ai-backed usage.
   */
  enterpriseConfig: z.record(z.unknown()).optional(),
});
export type ClaudeDesktopProfile = z.infer<typeof ClaudeDesktopProfile>;
